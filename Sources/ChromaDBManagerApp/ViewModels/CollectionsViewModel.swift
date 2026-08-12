import Foundation
import AppKit
import ChromaCore

/// «Коллекции»: browse what is in the database and work with it — create,
/// bind a model, add / edit / delete documents, filter, query, import, reset.
@MainActor
final class CollectionsViewModel: ObservableObject {
    // List
    @Published var collections: [ChromaCollection] = []
    /// Строка поиска по имени. Не сохраняется между запусками: это не
    /// настройка, а то, что человек печатает сейчас, — и найти список,
    /// отфильтрованный с прошлого раза, значит решить, что коллекции пропали.
    @Published var collectionSearch = ""

    /// Что показывать в списке: отбор по имени, затем выбранный порядок.
    /// Правило живёт в ядре и там же проверено.
    func visibleCollections(_ app: AppEnvironment) -> [ChromaCollection] {
        CollectionList.arrange(
            collections,
            order: app.settings.configuration.collectionListOrder,
            search: collectionSearch
        )
    }

    @Published var selectedID: String?
    /// Коллекция, которую попросили открыть извне, — по имени:
    /// идентификатора у просьбы нет, а список мог ещё не загрузиться.
    @Published var pendingSelectionName: String?
    /// Текст, который попросили добавить документом («Службы», интент — H3).
    @Published var pendingImportText: String?
    /// Файлы, которые перетащили и попросили добавить документами.
    @Published var pendingFileImport: [URL] = []
    @Published var isLoadingCollections = false
    /// Отметка `AppEnvironment.collectionsRevision`, на которой прочитан
    /// текущий список.
    private var appliedRevision = 0

    // Documents
    @Published var documents: [DocumentRecord] = []
    @Published var isLoadingDocuments = false
    @Published var canLoadMore = false
    static let pageSize = 100
    /// How many documents the collection had when this page was fetched.
    /// Paging by limit/offset has no guaranteed order, so a collection that
    /// changes underneath produces gaps and repeats — the app cannot fix that,
    /// but it can stop pretending the list is current.
    private var countWhenPageLoaded: Int?
    @Published var contentChangedNotice: String?

    // Filtering (stage 2A)
    @Published var filter = DocumentFilter()
    @Published var appliedFilterDescription: String?
    /// A server complaint about the filter, shown next to the builder instead
    /// of an alert that wipes what was typed.
    @Published var filterErrorMessage: String?
    @Published var savedFilters: [SavedFilter] = []
    @Published var savedFilterName = ""

    /// Vectors are pulled per document when its card is expanded — a page of
    /// 100 embeddings is megabytes for a preview of a few numbers.
    @Published var vectorPreviews: [String: [Double]] = [:]

    // Create collection
    @Published var newCollectionName = ""
    @Published var newCollectionModel: String = ""
    /// Cosine by default — the server's own default is `l2`, and the models
    /// this app works with are trained for cosine.
    @Published var newCollectionMetric: DistanceMetric = .cosine
    /// Index parameters, as typed. Empty means «не передавать», not «взять
    /// наше представление о серверном значении».
    @Published var draftEFConstruction = ""
    @Published var draftEFSearch = ""
    @Published var draftMaxNeighbors = ""

    /// Numbers the user actually typed. Anything unparseable is left out
    /// rather than silently turned into a default.
    var draftHNSW: HNSWParameters {
        HNSWParameters(
            efConstruction: Int(draftEFConstruction.trimmingCharacters(in: .whitespaces)),
            efSearch: Int(draftEFSearch.trimmingCharacters(in: .whitespaces)),
            maxNeighbors: Int(draftMaxNeighbors.trimmingCharacters(in: .whitespaces))
        )
    }
    @Published var isCreating = false

    /// What is wrong with the name as it is being typed — nil while the field
    /// is empty, because an untouched form is not an error.
    var nameProblem: String? {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return CollectionNaming.firstProblem(with: name)
    }

    // Delete (typing the name is the confirmation)
    @Published var deleteConfirmationText = ""
    @Published var showDeleteSheet = false
    /// set while a collection's documents are being paged into the trash
    /// before the collection itself is dropped — can take a while on a large
    /// collection, and rule 2 says it must not look like nothing is happening.
    @Published var isCapturingTrash = false

    // Add / edit a document
    @Published var documentText = ""
    @Published var documentID = ""
    @Published var documentMetadata = MetadataDraft()
    @Published var isSavingDocument = false
    @Published var showAddDocumentSheet = false
    @Published var editingDocumentID: String?
    /// Set when the id typed in the form is already taken. The server does not
    /// report this — it silently keeps the old document — so the form
    /// asks what to do.
    @Published var conflictingDocumentID: String?
    /// Chosen by «Перезаписать»: the next save goes through `upsert`.
    @Published var overwriteExistingDocument = false
    /// Context length of the collection's model; nil until it is known, or when
    /// LM Studio does not report one.
    @Published var documentContextLimit: Int?

    /// Whether the text being typed still fits the model.
    var documentContextVerdict: ContextVerdict {
        ContextBudget.check(documentText, contextLength: documentContextLimit)
    }

    // Import
    @Published var importTable: ImportTable?
    @Published var importMapping = ImportMapping()
    @Published var importFileName = ""
    @Published var showImportSheet = false
    @Published var isImporting = false
    @Published var importSummary: ImportSummary?
    /// How many documents an interrupted import managed to write. Set only
    /// when the run stopped part of the way through, and it is what the
    /// «continue» button starts from.
    @Published var importResumePoint: Int?
    /// What to do with rows whose id is already in the collection.
    @Published var importDuplicatePolicy: DuplicatePolicy = .skip
    private var importTask: Task<Void, Never>?

    // Metadata schema (stage 2B)
    @Published var schemaDraft = MetadataSchema(collectionName: "")
    @Published var schemaIssues: [SchemaViolation] = []
    @Published var documentViolations: [SchemaViolation] = []
    @Published var complianceReport: SchemaComplianceChecker.Report?
    @Published var complianceProgress: SchemaComplianceChecker.Progress?
    @Published var isCheckingCompliance = false
    /// Import rows that break the schema are skipped, not written silently.
    @Published var importViolations: [SchemaViolation] = []
    @Published var importSkippedInvalid = 0
    private var complianceTask: Task<Void, Never>?

    // Query
    @Published var queryText = ""
    @Published var numberOfResults = 5
    /// Whether the filter panel also narrows the semantic query.
    @Published var applyFilterToQuery = true
    @Published var isQuerying = false
    /// Results as the pipeline left them — with what each stage did to them
    /// still attached. Flattening to `QueryHit` here would throw away the
    /// collapse count and the context the user is entitled to see.
    @Published var hits: [RetrievalHit] = []
    /// What the pipeline did to get them. Kept for the last query only:
    /// it answers «почему такой результат», not «что было вчера».
    @Published var lastRetrieval: RetrievalDiagnostics?
    /// Collapsed by default, as E0.4 requires: the panel explains a result when
    /// asked, and is not part of reading one.
    @Published var showDiagnostics = false

    // Search profiles
    @Published var profiles: [SearchProfile] = []
    /// The one the collection searches with. Switching it here is what E0.2
    /// means by «профили переключаются из панели поиска»: the chosen one
    /// becomes the collection's default.
    @Published var activeProfileID: UUID?
    /// «Умный поиск». Off means the pipeline is skipped entirely and the query
    /// behaves exactly like the search of stage 2.
    @Published var smartSearchEnabled = true
    @Published var profileDraft: SearchProfile?
    @Published var showProfileEditor = false

    // History
    @Published var showHistory = false
    @Published var historySearch = ""
    @Published var history: [QueryHistoryEntry] = []

    // Bind a model to an existing collection
    @Published var bindModelSelection = ""
    @Published var showBindSheet = false
    /// Перенос коллекции пакетом `.chromaexport`.
    @Published var showExportSheet = false
    @Published var showImportPackageSheet = false
    @Published var isBinding = false

    // Reset
    @Published var resetConfirmationText = ""
    @Published var showResetSheet = false

    @Published var errorMessage: String?
    @Published var statusMessage: String?

    var selected: ChromaCollection? {
        collections.first { $0.id == selectedID }
    }

    /// Выполняет то, о чём попросили извне.
    ///
    /// Коллекция ищется по имени и только среди уже загруженных: просьба,
    /// пришедшая до загрузки списка, дождётся её — поле не обнуляется, пока
    /// коллекция не нашлась.
    func applyPendingRequest(_ app: AppEnvironment) {
        if let name = pendingSelectionName {
            if let match = collections.first(where: { $0.name == name }) {
                selectedID = match.id
                pendingSelectionName = nil
            }
        }
        if !pendingFileImport.isEmpty, selected != nil {
            let urls = pendingFileImport
            pendingFileImport = []
            Task { await importDroppedFiles(urls, app: app) }
        }
        if let text = pendingImportText, !collections.isEmpty {
            // Текст подставляется в форму добавления документа, но **не**
            // добавляется: приложение, пишущее в базу без подтверждения,
            // доверия не заслуживает.
            documentText = text
            showAddDocumentSheet = true
            pendingImportText = nil
        }
    }

    /// Добавляет перетащенные файлы документами в выбранную коллекцию.
    ///
    /// Через тот же пакетный импорт, что CSV и JSON: свой путь записи в базу
    /// разошёлся бы с ним на первой же схеме метаданных.
    func importDroppedFiles(_ urls: [URL], app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            let model = try await app.bindingService.requiredModel(for: collection)
            let lmStudio = try app.makeLMStudioClient()
            try await app.bindingService.ensureAvailable(model: model, lmStudio: lmStudio)
            let limit = await app.bindingService.contextLength(of: model, lmStudio: lmStudio)
            let registry = ExtractorRegistry.standard(log: app.logHandler)

            let prepared = await DroppedFileImport.prepare(
                urls: urls, contextLength: limit,
                extract: { url in
                    try await registry.extract(from: url, options: ExtractionOptions()).plainText
                }
            )
            if let problem = prepared.problem {
                errorMessage = problem
            }
            guard !prepared.documents.isEmpty else { return }

            let summary = try await app.queue.run(QueueTicket(
                title: String(localized: "Импорт в «\(collection.name)»"),
                priority: .manual,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { context in
                try await app.importService.importDocuments(
                    prepared.documents,
                    into: collection,
                    model: model,
                    chroma: client,
                    lmStudio: lmStudio,
                    binding: app.bindingService,
                    yield: { await context.yieldToHigherPriority() },
                    progress: { update in
                        Task { await context.report(progress: update.fraction, detail: update.stage) }
                    }
                )
            }
            statusMessage = String(localized: "Добавлено документов: \(summary.written).")
            await refresh(app)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Импорт")
        }
    }

    var isEditingExistingDocument: Bool { editingDocumentID != nil }

    // MARK: - Listing

    /// Перечитать список, если синхронизация могла его изменить.
    ///
    /// В один заход: «синхронизировать все» отмечает изменение по разу на
    /// источник, и без этого шестнадцать источников дали бы шестнадцать
    /// обращений к базе подряд. Проверка повторяется после чтения — отметка
    /// могла прийти, пока список читался.
    func refreshIfStale(_ app: AppEnvironment) async {
        // Чтение уже идёт: оно само дочитает до последней отметки.
        guard !isLoadingCollections else { return }
        while appliedRevision != app.collectionsRevision {
            await refresh(app)
        }
    }

    func refresh(_ app: AppEnvironment) async {
        // До всех выходов: иначе `refreshIfStale` крутился бы вхолостую,
        // пока приложение не подключено.
        appliedRevision = app.collectionsRevision
        guard let client = app.client else {
            collections = []
            documents = []
            return
        }
        isLoadingCollections = true
        errorMessage = nil
        defer { isLoadingCollections = false }

        do {
            collections = try await client.listCollections(withCounts: true)
            if let selectedID, !collections.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                documents = []
            }
            // Master-detail with an empty detail pane is a dead end: open the
            // first collection so the screen shows data straight away.
            if selectedID == nil, let first = collections.first {
                selectedID = first.id
                // Профили и выключатель «умный поиск» относятся к выбранной
                // коллекции, а выбор здесь происходит сам. Без этой строки
                // переключатель показывал состояние по умолчанию (включён),
                // пока хранилище говорило обратное, — и настройки профиля
                // «не срабатывали», потому что выполнялся обычный поиск.
                reloadProfiles(app)
                await loadDocuments(app, reset: true)
            }
            // Профили перечитываются и для уже выбранной коллекции: экран мог
            // быть открыт до того, как их кто-то изменил.
            reloadProfiles(app)
            refreshSavedFilters(app)
            app.log.record(.info, "Коллекции", "Загружено коллекций: \(collections.count)")
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    func select(_ collection: ChromaCollection, app: AppEnvironment) async {
        selectedID = collection.id
        hits = []
        lastRetrieval = nil
        vectorPreviews = [:]
        refreshSavedFilters(app)
        reloadProfiles(app)
        await loadDocuments(app, reset: true)
    }

    /// Pages of 100 through `limit`/`offset`, so a collection of any size never
    /// arrives in one lump.
    func loadDocuments(_ app: AppEnvironment, reset: Bool) async {
        guard let client = app.client, let collection = selected else { return }
        isLoadingDocuments = true
        errorMessage = nil
        defer { isLoadingDocuments = false }

        let offset = reset ? 0 : documents.count
        do {
            let page = try await client.getDocuments(
                collectionID: collection.id,
                limit: Self.pageSize,
                offset: offset,
                filter: filter.isEmpty ? nil : filter
            )
            if reset {
                documents = page
                vectorPreviews = [:]
                contentChangedNotice = nil
            } else {
                documents += page
            }
            canLoadMore = page.count == Self.pageSize
            await noteCollectionSize(client, collection: collection, reset: reset)
        } catch {
            if reset { documents = [] }
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    /// Compares the collection size with what it was when paging started.
    ///
    /// Unfiltered only: with a filter the total says nothing about how many
    /// rows match it.
    private func noteCollectionSize(_ client: ChromaClient, collection: ChromaCollection, reset: Bool) async {
        guard filter.isEmpty, let current = try? await client.count(collectionID: collection.id) else { return }
        if reset || countWhenPageLoaded == nil {
            countWhenPageLoaded = current
            return
        }
        if let previous = countWhenPageLoaded, previous != current {
            contentChangedNotice = String(localized: "Содержимое коллекции изменилось во время просмотра (было \(previous.plainDigits), стало \(current.plainDigits)). Обновите список — при листании порядок выдачи не гарантирован.")
            countWhenPageLoaded = current
        }
    }

    /// Re-reads exactly what is on screen instead of jumping back to the first
    /// page: losing the user's place is not a refresh.
    func reloadCurrentPage(_ app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        let span = max(documents.count, Self.pageSize)
        isLoadingDocuments = true
        defer { isLoadingDocuments = false }
        do {
            let page = try await client.getDocuments(
                collectionID: collection.id,
                limit: span,
                offset: 0,
                filter: filter.isEmpty ? nil : filter
            )
            documents = page
            vectorPreviews = [:]
            canLoadMore = page.count == span
            contentChangedNotice = nil
            countWhenPageLoaded = try? await client.count(collectionID: collection.id)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    // MARK: - Filtering

    func applyFilter(_ app: AppEnvironment) async {
        filterErrorMessage = nil
        do {
            // Fails fast on broken raw JSON instead of sending it to the server.
            _ = try filter.whereClause()
        } catch {
            filterErrorMessage = app.describe(error)
            return
        }
        // Values the server is known to reject are caught here, with the field
        // named, rather than coming back as «Invalid where clause».
        if let problem = filter.problems.first {
            filterErrorMessage = problem
            return
        }
        appliedFilterDescription = filter.isEmpty ? nil : describeFilter()
        await loadDocuments(app, reset: true)
        if !filter.isEmpty {
            app.log.record(.info, "Коллекции", "Фильтр: \(describeFilter())")
        }
    }

    func clearFilter(_ app: AppEnvironment) async {
        filter = DocumentFilter()
        appliedFilterDescription = nil
        filterErrorMessage = nil
        await loadDocuments(app, reset: true)
    }

    /// Switches between the tree and raw JSON without losing the filter.
    ///
    /// Going to JSON serialises what was built; coming back parses it. JSON the
    /// editor cannot represent keeps the raw mode and says why — the filter
    /// still runs as written.
    func toggleFilterJSONMode() {
        filterErrorMessage = nil
        if filter.usesRawJSON {
            var copy = filter
            let adoptedWhere = copy.adoptRawWhereIntoTree()
            let adoptedText = copy.adoptRawWhereDocumentIntoTree()
            guard adoptedWhere, adoptedText else {
                filterErrorMessage = String(localized: "Этот JSON конструктор показать не может — он останется в текстовом виде и будет отправлен как есть.")
                return
            }
            filter = copy
        } else {
            filter.moveTreeIntoRawJSON()
        }
    }

    // MARK: - Saved filters

    func refreshSavedFilters(_ app: AppEnvironment) {
        savedFilters = selected.map { app.savedFilters.filters(for: $0.name) } ?? []
    }

    func saveCurrentFilter(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        let name = savedFilterName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        app.savedFilters.save(name: name, filter: filter, collectionName: collection.name)
        savedFilterName = ""
        refreshSavedFilters(app)
        statusMessage = String(localized: "Фильтр «\(name)» сохранён.")
    }

    func applySavedFilter(_ saved: SavedFilter) {
        filter = saved.filter
        filterErrorMessage = nil
    }

    func deleteSavedFilter(_ saved: SavedFilter, app: AppEnvironment) {
        app.savedFilters.remove(id: saved.id)
        refreshSavedFilters(app)
    }

    /// Field names offered in the builder: the collection's schema when it has
    /// one, otherwise the keys actually present on the loaded page.
    func filterFieldSuggestions(_ app: AppEnvironment) -> [String] {
        if let schema = schema(for: selected, app: app), !schema.fields.isEmpty {
            return Set(schema.fields.map(\.key) + knownMetadataKeys).sorted()
        }
        return knownMetadataKeys
    }

    private func describeFilter() -> String {
        [filter.whereJSONString(), filter.whereDocumentJSONString()]
            .compactMap { $0 }
            .joined(separator: " + ")
    }

    /// Metadata keys seen on the current page — offered as suggestions in the
    /// condition builder so the user does not have to remember field names.
    var knownMetadataKeys: [String] {
        var keys = Set<String>()
        for document in documents {
            for key in document.metadata?.keys ?? [:].keys where !key.hasPrefix("_cdbm_") {
                keys.insert(key)
            }
        }
        return keys.sorted()
    }

    // MARK: - Vector preview

    func loadVector(for document: DocumentRecord, app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        guard vectorPreviews[document.id] == nil else { return }
        do {
            let vectors = try await client.embeddings(collectionID: collection.id, ids: [document.id])
            if let vector = vectors[document.id] {
                vectorPreviews[document.id] = vector
            }
        } catch {
            app.log.record(.warning, "Коллекции", "Не удалось получить вектор \(document.id): \(app.describe(error))")
        }
    }

    // MARK: - Create

    func createCollection(_ app: AppEnvironment) async {
        guard let client = app.client else { return }
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMessage = String(localized: "Введите имя коллекции.")
            return
        }
        if let problem = CollectionNaming.firstProblem(with: name) {
            errorMessage = String(localized: "\(problem) Подходящий вариант: «\(CollectionNaming.sanitize(name))».")
            return
        }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            var metadata: ChromaMetadata = [:]
            let model = newCollectionModel.trimmingCharacters(in: .whitespaces)
            if !model.isEmpty {
                let lmStudio = try app.makeLMStudioClient()
                let dimension = try await app.bindingService.dimension(of: model, lmStudio: lmStudio)
                metadata[CollectionBindingKeys.model] = .string(model)
                metadata[CollectionBindingKeys.dimension] = .int(dimension)
            }
            let created = try await client.createCollection(
                name: name,
                metadata: metadata,
                configuration: CollectionConfiguration(metric: newCollectionMetric, hnsw: draftHNSW),
                getOrCreate: false
            )
            // Read back, not assumed: the request succeeding says nothing about
            // which metric the collection ended up with.
            let stored = created.space
            let metricNote = stored == newCollectionMetric
                ? String(localized: "Метрика: \(newCollectionMetric.shortTitle).")
                : String(localized: "Внимание: запрошена метрика \(newCollectionMetric.shortTitle), а сервер записал \(stored?.shortTitle ?? "неизвестную"). Изменить её у существующей коллекции нельзя.")
            statusMessage = (model.isEmpty
                ? String(localized: "Коллекция «\(name)» создана без модели: читать её можно, добавлять документы — нет, пока не указана модель.")
                : String(localized: "Коллекция «\(name)» создана с моделью \(model).")) + " " + metricNote
            newCollectionName = ""
            await refresh(app)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    // MARK: - Delete collection

    func deleteSelected(_ app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        guard deleteConfirmationText == collection.name else {
            errorMessage = String(localized: "Имя введено неверно — удаление отменено.")
            return
        }
        let usesTrash = app.settings.configuration.trashEnabled
        do {
            if usesTrash {
                isCapturingTrash = true
                defer { isCapturingTrash = false }
                // If the capture fails partway, the collection must stay:
                // deleting it anyway would defeat the one thing J3 exists for
                // (rule 1, Приложение 5 — a manual delete has to stay reversible).
                try await captureCollectionToTrash(collection, client: client, app: app)
            }
            try await client.deleteCollection(name: collection.name)
            statusMessage = usesTrash
                ? String(localized: "Коллекция «\(collection.name)» удалена — документы сохранены в корзине.")
                : String(localized: "Коллекция «\(collection.name)» удалена.")
            deleteConfirmationText = ""
            showDeleteSheet = false
            selectedID = nil
            documents = []
            await refresh(app)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    /// Pages through the whole collection, vectors included, before it is
    /// dropped. Same paging shape as re-embedding; the bulk vector fetch is
    /// the A3.3 exception a single-document capture already has (rule 8,
    /// Приложение 5), extended to the whole list because a collection delete
    /// has no smaller unit to fall back to.
    private func captureCollectionToTrash(_ collection: ChromaCollection, client: ChromaClient, app: AppEnvironment) async throws {
        let metric = collection.space
        let model = collection.boundModel
        let dimension = collection.effectiveDimension
        let pageSize = 200
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await client.getDocuments(collectionID: collection.id, limit: pageSize, offset: offset)
            guard !page.isEmpty else { break }
            let vectors = try await client.embeddings(collectionID: collection.id, ids: page.map(\.id))
            let batch = page.map { document in
                TrashEntry(
                    documentID: document.id,
                    document: document.document,
                    metadata: document.metadata,
                    embedding: vectors[document.id],
                    collectionName: collection.name,
                    collectionMetric: metric,
                    collectionModel: model,
                    collectionDimension: dimension,
                    reason: .collection
                )
            }
            // Бросит, если страница не легла на диск: тогда коллекция не
            // удаляется вовсе. Часть страниц при этом уже в корзине —
            // и это правильная сторона ошибки: лишние копии живой коллекции
            // безобидны, а недостающие копии удалённой невосполнимы.
            try app.trash.record(batch)
            offset += page.count
            if page.count < pageSize { break }
        }
    }

    // MARK: - Model binding

    func bindModel(_ app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        let model = bindModelSelection.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else {
            errorMessage = String(localized: "Выберите модель.")
            return
        }
        isBinding = true
        defer { isBinding = false }

        do {
            let lmStudio = try app.makeLMStudioClient()
            let binding = try await app.bindingService.bind(
                model: model,
                to: collection,
                chroma: client,
                lmStudio: lmStudio
            )
            statusMessage = String(localized: "Коллекция «\(collection.name)» привязана к модели \(binding.model) (размерность \(binding.dimension.plainDigits)).")
            showBindSheet = false
            await refresh(app)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    // MARK: - Metadata schema

    func schema(for collection: ChromaCollection?, app: AppEnvironment) -> MetadataSchema? {
        guard let collection else { return nil }
        guard let schema = app.schemaStore.schema(for: collection.name), !schema.isEmpty else { return nil }
        return schema
    }

    func beginEditingSchema(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        schemaDraft = app.schemaStore.schema(for: collection.name)
            ?? MetadataSchema(collectionName: collection.name)
        schemaIssues = []
        complianceReport = nil
    }

    func addSchemaField() {
        schemaDraft.fields.append(MetadataField())
    }

    func removeSchemaField(_ field: MetadataField) {
        schemaDraft.fields.removeAll { $0.id == field.id }
    }

    func saveSchema(_ app: AppEnvironment) {
        let issues = MetadataSchemaValidator().validateSchema(schemaDraft)
        schemaIssues = issues
        guard issues.isEmpty else { return }

        app.schemaStore.save(schemaDraft)
        statusMessage = String(localized: "Схема коллекции «\(schemaDraft.collectionName)» сохранена.")
    }

    func deleteSchema(_ app: AppEnvironment) {
        app.schemaStore.remove(collectionName: schemaDraft.collectionName)
        schemaDraft = MetadataSchema(collectionName: schemaDraft.collectionName)
        statusMessage = String(localized: "Схема удалена — правила больше не применяются.")
    }

    /// Drafts a schema from the documents already on screen — quicker than
    /// describing fields from memory, and the result stays editable.
    func inferSchema(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        guard !documents.isEmpty else {
            schemaIssues = [SchemaViolation(
                field: "",
                kind: .unexpectedField,
                message: String(localized: "Нет загруженных документов, из которых можно вывести поля.")
            )]
            return
        }
        let inferred = MetadataSchema.inferred(collectionName: collection.name, from: documents)
        guard !inferred.fields.isEmpty else {
            schemaIssues = [SchemaViolation(
                field: "",
                kind: .unexpectedField,
                message: String(localized: "В загруженных документах нет пользовательских метаданных.")
            )]
            return
        }
        schemaDraft.fields = inferred.fields
        schemaIssues = []
        app.log.record(.info, "Схемы", "Черновик схемы «\(collection.name)» выведен из \(documents.count) документов: полей \(inferred.fields.count)")
    }

    func exportSchema(_ app: AppEnvironment) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт схемы")
        panel.nameFieldStringValue = "\(schemaDraft.collectionName)-schema.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.schemaStore.exportJSON(schemaDraft).write(to: url, options: .atomic)
            statusMessage = String(localized: "Схема выгружена в \(url.lastPathComponent).")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    func importSchema(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт схемы")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            schemaDraft = try app.schemaStore.importJSON(data, collectionName: collection.name)
            schemaIssues = MetadataSchemaValidator().validateSchema(schemaDraft)
            statusMessage = String(localized: "Схема загружена из \(url.lastPathComponent) и применена к коллекции «\(collection.name)».")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    /// Walks the whole collection and reports what does not match — a report,
    /// not a migration: nothing is rewritten.
    func runComplianceCheck(_ app: AppEnvironment) {
        guard !isCheckingCompliance, let collection = selected, let client = app.client else { return }
        let schema = schemaDraft
        guard !schema.isEmpty else {
            schemaIssues = [SchemaViolation(field: "", kind: .unexpectedField, message: String(localized: "Сначала опишите хотя бы одно поле."))]
            return
        }

        isCheckingCompliance = true
        complianceReport = nil
        complianceProgress = nil

        complianceTask = Task { [weak self] in
            do {
                let report = try await SchemaComplianceChecker().check(
                    collection: collection,
                    schema: schema,
                    chroma: client
                ) { update in
                    Task { @MainActor in self?.complianceProgress = update }
                }
                await MainActor.run {
                    self?.complianceReport = report
                    app.log.record(
                        report.isClean ? .success : .warning,
                        "Схемы",
                        "Проверка «\(collection.name)»: просмотрено \(report.checked), не соответствуют \(report.offending)"
                    )
                }
            } catch is CancellationError {
                await MainActor.run { self?.statusMessage = String(localized: "Проверка отменена.") }
            } catch {
                await MainActor.run { self?.errorMessage = app.describe(error) }
            }
            await MainActor.run {
                self?.isCheckingCompliance = false
                self?.complianceProgress = nil
            }
        }
    }

    func cancelComplianceCheck() {
        complianceTask?.cancel()
        complianceTask = nil
    }

    // MARK: - Add / edit a document

    func beginAddingDocument(_ app: AppEnvironment) {
        editingDocumentID = nil
        documentText = ""
        documentID = ""
        conflictingDocumentID = nil
        overwriteExistingDocument = false
        // The form opens with the schema's fields and defaults already in place.
        documentMetadata = MetadataDraft.seeded(from: schema(for: selected, app: app), existing: nil)
        documentViolations = []
        showAddDocumentSheet = true
        loadContextLimit(app)
    }

    func beginEditing(_ document: DocumentRecord, app: AppEnvironment) {
        editingDocumentID = document.id
        documentText = document.document ?? ""
        documentID = document.id
        documentMetadata = MetadataDraft.seeded(from: schema(for: selected, app: app), existing: document.metadata)
        documentViolations = []
        showAddDocumentSheet = true
        loadContextLimit(app)
    }

    /// Context of the model bound to the open collection, so the form can warn
    /// while the text is still being typed rather than after the write.
    private func loadContextLimit(_ app: AppEnvironment) {
        documentContextLimit = nil
        guard let collection = selected else { return }
        Task { [weak self] in
            guard let model = try? await app.bindingService.requiredModel(for: collection),
                  let lmStudio = try? app.makeLMStudioClient() else { return }
            let limit = await app.bindingService.contextLength(of: model, lmStudio: lmStudio)
            await MainActor.run { self?.documentContextLimit = limit }
        }
    }

    /// «Перезаписать» — the same write, but as an upsert.
    func overwriteConflictingDocument(_ app: AppEnvironment) async {
        overwriteExistingDocument = true
        conflictingDocumentID = nil
        await saveDocument(app)
    }

    /// «Показать существующий» — close the form and open what is already there.
    func revealConflictingDocument(_ app: AppEnvironment) async {
        guard let identifier = conflictingDocumentID else { return }
        conflictingDocumentID = nil
        showAddDocumentSheet = false
        filter = DocumentFilter()
        documentIDToReveal = identifier
        await loadDocuments(app, reset: true)
        statusMessage = String(localized: "Документ \(identifier) уже есть в коллекции — открыт в списке.")
    }

    /// Id the list should scroll to and expand after «показать существующий».
    @Published var documentIDToReveal: String?

    /// Loads the document text from a file (spec: "текст вручную или из файла").
    func loadDocumentTextFromFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Выберите текстовый файл")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            errorMessage = String(localized: "Не удалось прочитать файл как текст.")
            return
        }
        documentText = text
        if documentID.isEmpty { documentID = url.lastPathComponent }
        var draft = documentMetadata
        draft.rows.append(MetadataDraft.Row(key: "source_file", value: url.lastPathComponent))
        documentMetadata = draft
    }

    /// One document is one vector: no chunking at this stage.
    /// Editing text always recomputes the embedding — ChromaDB keeps the old
    /// vector otherwise, and search would silently point at stale text.
    func saveDocument(_ app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        let text = documentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = String(localized: "Введите текст документа.")
            return
        }
        let duplicates = documentMetadata.duplicateKeys
        guard duplicates.isEmpty else {
            errorMessage = String(localized: "Повторяющиеся ключи метаданных: \(duplicates.joined(separator: ", ")).")
            return
        }

        isSavingDocument = true
        errorMessage = nil
        defer { isSavingDocument = false }

        do {
            let model = try await app.bindingService.requiredModel(for: collection)
            let lmStudio = try app.makeLMStudioClient()
            try await app.bindingService.ensureAvailable(model: model, lmStudio: lmStudio)

            // Nothing downstream would catch this: LM Studio answers 200 for a
            // text of any length and quietly embeds only its beginning.
            let limit = await app.bindingService.contextLength(of: model, lmStudio: lmStudio)
            let verdict = ContextBudget.check(text, contextLength: limit)
            if case .tooLong(let tokens, let allowed) = verdict {
                throw ContextError.tooLong(estimatedTokens: tokens, limit: allowed, model: model)
            }
            if let warning = verdict.message {
                app.log.record(.warning, "Коллекции", warning)
            }

            // Adding one document is a model call like any other: it waits its
            // turn, and it goes first among the waiting because the user is
            // sitting in front of the form.
            let vector = try await app.queue.run(QueueTicket(
                title: String(localized: "Эмбеддинг документа для «\(collection.name)»"),
                priority: .interactive,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { _ in
                try await lmStudio.embed(text: text, model: model)
            }
            try await app.bindingService.validate(vectorLength: vector.count, for: collection)

            var metadata = documentMetadata.metadata()
            // Schema rules apply here and to automatic ingestion alike — one
            // model, two suppliers of values.
            if let schema = schema(for: collection, app: app) {
                let validator = MetadataSchemaValidator()
                metadata = validator.normalised(metadata, schema: schema)
                let result = validator.validate(metadata, against: schema, documentID: editingDocumentID)
                guard result.isValid else {
                    documentViolations = result.violations
                    errorMessage = String(localized: "Документ не соответствует схеме коллекции — исправьте отмеченные поля.")
                    return
                }
                documentViolations = []
            }

            if let existingID = editingDocumentID {
                // Editing keeps whatever provenance the document had; one that
                // arrives without the field was made outside this app, and the
                // write we are doing anyway is where that gets recorded.
                metadata.carryOrigin(from: documents.first { $0.id == existingID }?.metadata)
                try await client.updateDocuments(collectionID: collection.id, updates: [
                    DocumentUpdate(id: existingID, document: text, embedding: vector, metadata: metadata)
                ])
                statusMessage = String(localized: "Документ \(existingID) обновлён, вектор пересчитан моделью \(model).")
            } else {
                metadata.stamp(origin: .manual)
                let identifier = documentID.trimmingCharacters(in: .whitespaces).isEmpty
                    ? UUID().uuidString
                    : documentID.trimmingCharacters(in: .whitespaces)

                // `add` on an existing id answers 201 and changes nothing
                //, so the check has to happen here — otherwise the form
                // would report success and quietly drop the text.
                if !overwriteExistingDocument,
                   try await client.existingIDs(collectionID: collection.id, ids: [identifier]).contains(identifier) {
                    conflictingDocumentID = identifier
                    return
                }
                let record = EmbeddedRecord(id: identifier, document: text, embedding: vector, metadata: metadata)
                if overwriteExistingDocument {
                    try await client.upsert(collectionID: collection.id, records: [record])
                    statusMessage = String(localized: "Документ \(identifier) перезаписан (модель \(model)).")
                } else {
                    try await client.add(collectionID: collection.id, records: [record])
                    statusMessage = String(localized: "Документ добавлен (id \(identifier), модель \(model), размерность \(vector.count.plainDigits)).")
                }
            }

            showAddDocumentSheet = false
            editingDocumentID = nil
            documentText = ""
            documentID = ""
            documentMetadata = MetadataDraft()
            conflictingDocumentID = nil
            overwriteExistingDocument = false
            await refresh(app)
            await loadDocuments(app, reset: true)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    /// Metadata-only edit: no re-embedding needed, so the vector is untouched.
    func saveMetadataOnly(for document: DocumentRecord, draft: MetadataDraft, app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        let duplicates = draft.duplicateKeys
        guard duplicates.isEmpty else {
            errorMessage = String(localized: "Повторяющиеся ключи метаданных: \(duplicates.joined(separator: ", ")).")
            return
        }
        var metadata = draft.metadata()
        // `update` replaces the metadata wholesale, so provenance has to be
        // carried over explicitly or an edit would erase it.
        metadata.carryOrigin(from: document.metadata)
        if let schema = schema(for: collection, app: app) {
            let validator = MetadataSchemaValidator()
            metadata = validator.normalised(metadata, schema: schema)
            let result = validator.validate(metadata, against: schema, documentID: document.id)
            guard result.isValid else {
                documentViolations = result.violations
                errorMessage = result.violations.map(\.message).joined(separator: "\n")
                return
            }
        }

        do {
            try await client.updateDocuments(collectionID: collection.id, updates: [
                DocumentUpdate(id: document.id, metadata: metadata)
            ])
            statusMessage = String(localized: "Метаданные документа \(document.id) обновлены.")
            await loadDocuments(app, reset: true)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    func deleteDocument(_ document: DocumentRecord, app: AppEnvironment) async {
        guard let client = app.client, let collection = selected else { return }
        let usesTrash = app.settings.configuration.trashEnabled
        do {
            if usesTrash {
                let vector = try await resolvedVector(for: document, collection: collection, client: client)
                // Бросит, если копия не легла на диск, — удаления тогда
                // не будет вовсе.
                try app.trash.record(TrashEntry(
                    documentID: document.id,
                    document: document.document,
                    metadata: document.metadata,
                    embedding: vector,
                    collectionName: collection.name,
                    collectionMetric: collection.space,
                    collectionModel: collection.boundModel,
                    collectionDimension: collection.effectiveDimension,
                    reason: .document
                ))
            }
            try await client.deleteDocuments(collectionID: collection.id, ids: [document.id])
            documents.removeAll { $0.id == document.id }
            statusMessage = usesTrash
                ? String(localized: "Документ \(document.id) удалён — копия сохранена в корзине.")
                : String(localized: "Документ \(document.id) удалён.")
            await refresh(app)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    /// The cached preview if the row was already expanded, otherwise one
    /// fetch — the same A3.3 exception `loadVector` already uses for a single
    /// document (rule 8, Приложение 5).
    private func resolvedVector(for document: DocumentRecord, collection: ChromaCollection, client: ChromaClient) async throws -> [Double]? {
        if let cached = vectorPreviews[document.id] { return cached }
        let vectors = try await client.embeddings(collectionID: collection.id, ids: [document.id])
        return vectors[document.id]
    }

    // MARK: - Import

    func chooseImportFile(_ app: AppEnvironment) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Выберите CSV или JSON")
        panel.message = String(localized: "Одна строка файла — один документ. Разбиение на чанки появится на подэтапе 2C.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let table = try ImportService().readTable(at: url)
            importTable = table
            importMapping = ImportMapping.suggested(for: table)
            importFileName = url.lastPathComponent
            importSummary = nil
            showImportSheet = true
            app.log.record(.info, "Импорт", "Файл \(url.lastPathComponent): колонок \(table.columns.count), строк \(table.rowCount)")
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Импорт")
        }
    }

    func runImport(_ app: AppEnvironment, resume: Bool = false) {
        guard !isImporting, let table = importTable, let collection = selected else { return }
        guard let client = app.client else { return }

        let resumePoint = resume ? (importResumePoint ?? 0) : 0
        isImporting = true
        importResumePoint = nil
        importSummary = nil
        importViolations = []
        importSkippedInvalid = 0
        errorMessage = nil

        let mapping = importMapping
        let policy = importDuplicatePolicy
        let ticket = QueueTicket(
            title: String(localized: "Импорт в «\(collection.name)»"),
            priority: .manual,
            group: .lmStudio,
            connectionID: app.connectionID,
            resumable: ResumableRequest(
                kind: .importDocuments,
                subject: collection.name,
                title: String(localized: "Импорт в «\(collection.name)»")
            )
        )
        importTask = Task { [weak self] in
            // Одна ссылка на всю задачу вместо «weak self» в каждом
            // вложенном замыкании: перезахват внешней переменной из
            // параллельно исполняемого кода — это гонка.
            guard let self else { return }
            do {
                var prepared = try ImportService.prepare(table, mapping: mapping)

                // Rows that break the schema are skipped and reported, never
                // written quietly.
                if let schema = self.schema(for: collection, app: app) {
                    let validator = MetadataSchemaValidator()
                    var accepted: [PreparedDocument] = []
                    var violations: [SchemaViolation] = []
                    var skipped = 0
                    for document in prepared.documents {
                        let metadata = validator.normalised(document.metadata, schema: schema)
                        let result = validator.validate(metadata, against: schema, documentID: document.id)
                        if result.isValid {
                            accepted.append(PreparedDocument(id: document.id, text: document.text, metadata: metadata))
                        } else {
                            skipped += 1
                            if violations.count < 50 { violations.append(contentsOf: result.violations) }
                        }
                    }
                    prepared = (documents: accepted, skipped: prepared.skipped)
                    let capturedViolations = violations
                    let capturedSkipped = skipped
                    await MainActor.run {
                        self.importViolations = capturedViolations
                        self.importSkippedInvalid = capturedSkipped
                    }
                }

                let model = try await app.bindingService.requiredModel(for: collection)
                let lmStudio = try app.makeLMStudioClient()
                try await app.bindingService.ensureAvailable(model: model, lmStudio: lmStudio)

                // Снимок до постановки в очередь: `prepared` — изменяемая
                // переменная, а замыкание задачи исполняется параллельно.
                // Читать её оттуда — гонка, о которой компилятор и говорит.
                let documents = prepared.documents
                let skippedEmpty = prepared.skipped
                let summary = try await app.queue.run(ticket) { context in
                    await app.queue.setCanceller(for: context.id) { [weak self] in
                        Task { @MainActor in self?.cancelImport() }
                    }
                    return try await app.importService.importDocuments(
                        documents,
                        skippedEmpty: skippedEmpty,
                        into: collection,
                        model: model,
                        chroma: client,
                        lmStudio: lmStudio,
                        binding: app.bindingService,
                        startingAt: resumePoint,
                        duplicates: policy,
                        yield: { await context.yieldToHigherPriority() }
                    ) { update in
                        Task {
                            await context.report(
                                progress: update.fraction,
                                detail: "\(update.stage): \(update.processed) из \(update.total)"
                            )
                        }
                    }
                }
                await MainActor.run {
                    self.importSummary = summary
                    self.statusMessage = String(localized: "Импортировано документов: \(summary.written).")
                    app.notify(summary.notice)
                }
                await self.refresh(app)
                await self.loadDocuments(app, reset: true)
            } catch is CancellationError {
                await MainActor.run {
                    self.statusMessage = String(localized: "Импорт отменён. Уже записанные документы остались в коллекции.")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = app.describe(error)
                    // Only an interrupted run has a place to continue from.
                    if case ImportError.interrupted(let written, _, _) = error, written > 0 {
                        self.importResumePoint = written
                    }
                }
                app.report(error, category: "Импорт")
                await MainActor.run {
                    app.notify(.failure(
                        kind: .importDocuments,
                        subject: collection.name,
                        reason: app.describe(error)
                    ))
                }
                await self.refresh(app)
            }
            await MainActor.run {
                self.isImporting = false
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
    }

    // MARK: - Query

    func runQuery(_ app: AppEnvironment) async {
        // Подключение проверяется, а клиент здесь не нужен: конвейер
        // собирает его сам. Связка осталась от прежней редакции.
        guard app.client != nil, let collection = selected else { return }
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = String(localized: "Введите текст запроса.")
            return
        }

        isQuerying = true
        errorMessage = nil
        hits = []
        // The panel must never explain the previous query while the new one is
        // on screen: stale diagnostics are worse than none.
        lastRetrieval = nil
        defer { isQuerying = false }

        do {
            // Конвейер собирается там же, где и для быстрого поиска из
            // строки меню: второй реализации поиска в приложении нет.
            let prepared = try await app.prepareSearch(for: collection)
            let model = prepared.model
            let profile = prepared.profile
            let smartSearch = prepared.smartSearchEnabled
            let pipeline = prepared.pipeline

            let outcome = try await pipeline.run(
                RetrievalRequest(
                    text: text,
                    collectionID: collection.id,
                    collectionName: collection.name,
                    nResults: numberOfResults,
                    // The filter panel narrows the search as well as the
                    // browser: «похоже на это, но только среди прошлогодних» is
                    // one request, not two.
                    filter: applyFilterToQuery && !filter.isEmpty ? filter : nil,
                    // MMR has to turn a distance into a relevance, and only a
                    // bounded metric allows that honestly.
                    metric: collection.space
                ),
                profile: profile
            )
            // The vectors were carried for MMR and have no business on screen
            // or in memory afterwards.
            hits = outcome.hits.map { hit in
                var stripped = hit
                stripped.embedding = nil
                return stripped
            }
            var diagnostics = outcome.diagnostics
            // Said once, at the top, instead of eight stages each blaming the
            // profile for something the switch decided.
            if !smartSearch {
                diagnostics.note = String(localized: "Умный поиск выключен — запрос выполнен как обычный векторный поиск, настройки профиля не применялись.")
            }
            lastRetrieval = diagnostics
            statusMessage = String(localized: "Найдено результатов: \(hits.count) (модель \(model)).")
            app.log.record(.info, "Коллекции", "Запрос к «\(collection.name)»: \(hits.count) результатов, модель \(model)")

            // written after the run, with what the run actually cost.
            app.queryHistory.record(QueryHistoryEntry(
                text: text,
                collectionName: collection.name,
                profileName: profile.name,
                profileID: profile.id,
                filter: applyFilterToQuery && !filter.isEmpty ? filter : nil,
                resultCount: hits.count,
                duration: outcome.diagnostics.totalDuration
            ))
            reloadHistory(app)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    // MARK: - Search profiles

    func reloadProfiles(_ app: AppEnvironment) {
        guard let collection = selected else {
            profiles = []
            activeProfileID = nil
            return
        }
        profiles = app.searchProfiles.profiles(for: collection.name)
        activeProfileID = app.searchProfiles.defaultProfile(for: collection.name).id
        smartSearchEnabled = app.searchProfiles.isPipelineEnabled(for: collection.name)
    }

    /// The switch of E0.1, as a switch and nothing more: it changes what runs,
    /// never what is stored in the profile. Turning it back on has to return
    /// the tuning untouched, or nobody would dare turn it off.
    func setSmartSearch(_ enabled: Bool, app: AppEnvironment) {
        guard let collection = selected else { return }
        app.searchProfiles.setPipelineEnabled(enabled, for: collection.name)
        smartSearchEnabled = enabled
        statusMessage = enabled
            ? String(localized: "Умный поиск включён: запросы идут через конвейер профиля «\(app.searchProfiles.defaultProfile(for: collection.name).name)».")
            : String(localized: "Умный поиск выключен: запросы выполняются как обычный векторный поиск. Настройки профиля сохранены.")
    }

    /// Picking a profile in the panel makes it the collection's default — that
    /// is what «переключаются из панели поиска» means, and a second notion of
    /// «выбранный, но не по умолчанию» would only make «какой применился»
    /// ambiguous.
    func activateProfile(id: UUID, app: AppEnvironment) {
        guard var profile = app.searchProfiles.profile(id: id) else { return }
        profile.isDefault = true
        app.searchProfiles.save(profile)
        reloadProfiles(app)
        statusMessage = String(localized: "Профиль поиска: «\(profile.name)».")
    }

    func newProfile(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        // A new profile starts from the defaults of the specification, not from
        // whatever is on screen: «создать» and «дублировать» are different
        // actions and must not quietly be the same one.
        profileDraft = SearchProfile(
            name: String(localized: "Новый профиль"),
            collectionName: collection.name,
            isDefault: profiles.isEmpty
        )
        showProfileEditor = true
    }

    func duplicateActiveProfile(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        var copy = app.searchProfiles.defaultProfile(for: collection.name)
        copy.id = UUID()
        copy.name = String(localized: "\(copy.name) — копия")
        copy.isDefault = false
        profileDraft = copy
        showProfileEditor = true
    }

    func editActiveProfile(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        profileDraft = app.searchProfiles.defaultProfile(for: collection.name)
        showProfileEditor = true
    }

    func saveProfileDraft(_ app: AppEnvironment) {
        guard let draft = profileDraft else { return }
        let saved = app.searchProfiles.save(draft)
        showProfileEditor = false
        profileDraft = nil
        reloadProfiles(app)
        statusMessage = String(localized: "Профиль поиска «\(saved.name)» сохранён. Переэмбеддинг не требуется — это параметры запроса, а не свойство данных.")
    }

    /// Deleting a profile deletes a profile. Nothing in the collection changes,
    /// and rule 1 of Приложение 5 is not in play — but the collection is left
    /// with a working search either way: the store hands the default over to
    /// whatever remains.
    func deleteActiveProfile(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        let profile = app.searchProfiles.defaultProfile(for: collection.name)
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        app.searchProfiles.remove(id: profile.id)
        reloadProfiles(app)
        statusMessage = String(localized: "Профиль «\(profile.name)» удалён. Документы коллекции не затронуты.")
    }

    func exportProfiles(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        let subject = app.searchProfiles.profiles(for: collection.name)
        guard !subject.isEmpty else {
            errorMessage = String(localized: "У коллекции нет сохранённых профилей — выгружать нечего.")
            return
        }
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт профилей поиска")
        panel.nameFieldStringValue = "\(collection.name)-search-profiles.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.searchProfiles.exportData(subject).write(to: url, options: .atomic)
            statusMessage = String(localized: "Профилей выгружено: \(subject.count) → \(url.lastPathComponent).")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    /// Import adds; it never overwrites. The file may have come from the machine
    /// these profiles still live on, so every one arrives with a new id and
    /// without `isDefault` — which profile a collection searches with stays the
    /// user's decision (rule 2).
    func importProfiles(_ app: AppEnvironment) {
        guard let collection = selected else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт профилей поиска")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try app.searchProfiles.importing(try Data(contentsOf: url), into: collection.name)
            for profile in imported { app.searchProfiles.save(profile) }
            reloadProfiles(app)
            statusMessage = String(localized: "Загружено профилей: \(imported.count). Действующий профиль не изменился — выберите его сами.")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    // MARK: - History

    func reloadHistory(_ app: AppEnvironment) {
        history = app.queryHistory.search(historySearch, in: selected?.name)
    }

    /// Puts a past query back into the form. Running it is a separate click:
    /// «повторить» must not fire a search the moment a list item is touched.
    func restore(_ entry: QueryHistoryEntry) {
        queryText = entry.text
        if let stored = entry.filter {
            filter = stored
            applyFilterToQuery = true
        }
    }

    func togglePinned(_ entry: QueryHistoryEntry, app: AppEnvironment) {
        app.queryHistory.setPinned(!entry.isPinned, id: entry.id)
        reloadHistory(app)
    }

    /// 1 will read these. Until the stand exists the mark lives here rather
    /// than in a storage format nobody has fixed yet.
    func toggleChosenForEvaluation(_ entry: QueryHistoryEntry, app: AppEnvironment) {
        let wasChosen = entry.isChosenForEvaluation
        app.queryHistory.setChosenForEvaluation(!wasChosen, id: entry.id)
        reloadHistory(app)

        guard !wasChosen else {
            // Снятие отметки не выносит запрос из набора: набор — отдельная
            // работа пользователя, и удалять оттуда молча нельзя (правило 1).
            // Куда идти, чтобы удалить, — теперь правда: карточка набора на
            // экране «Оценка» это умеет. До обещание было пустым.
            statusMessage = String(localized: "Отметка снята. Из набора запросов запрос при этом не удалён — удалить его можно на экране «Оценка», в карточке набора.")
            return
        }

        // Отметка теперь не только флаг: у стенда появилось хранилище, и запрос
        // отправляется прямо в набор (D1.1 — «основной способ наполнения»).
        let set = app.querySets.defaultSet()
        let added = app.querySets.add([EvaluationQuery(entry)], to: set.id)
        let total = app.querySets.set(id: set.id)?.queries.count ?? 0
        statusMessage = added > 0
            ? String(localized: "Запрос добавлен в набор «\(set.name)» — теперь в нём \(total). Прогнать его по вариантам можно в стенде оценки.")
            : String(localized: "Такой запрос в наборе «\(set.name)» уже есть — в нём \(total).")
    }

    func removeFromHistory(_ entry: QueryHistoryEntry, app: AppEnvironment) {
        app.queryHistory.remove(id: entry.id)
        reloadHistory(app)
    }

    func clearHistory(_ app: AppEnvironment) {
        app.queryHistory.clear(collectionName: selected?.name)
        reloadHistory(app)
        statusMessage = String(localized: "История запросов очищена.")
    }

    // MARK: - Reset

    func resetDatabase(_ app: AppEnvironment) async {
        guard let client = app.client else { return }
        guard resetConfirmationText == "СБРОС" else {
            errorMessage = String(localized: "Введите СБРОС заглавными буквами для подтверждения.")
            return
        }
        do {
            try await client.reset()
            statusMessage = String(localized: "База сброшена.")
            resetConfirmationText = ""
            showResetSheet = false
            selectedID = nil
            documents = []
            await refresh(app)
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Коллекции")
        }
    }

    /// Whether the active connection is even allowed to reset.
    func resetAvailability(_ app: AppEnvironment) -> String? {
        switch app.settings.configuration.mode {
        case .localDatabase:
            return nil
        case .server:
            guard let profile = app.settings.activeProfile else { return nil }
            if profile.kind == .managed && !profile.allowReset {
                return String(localized: "В профиле «\(profile.name)» выключен allow_reset — сервер отклонит сброс. Включите его в настройках профиля и перезапустите сервер.")
            }
            if profile.kind == .external {
                return String(localized: "Внешний сервер: сброс сработает, только если на нём включён allow_reset.")
            }
            return nil
        }
    }
}
