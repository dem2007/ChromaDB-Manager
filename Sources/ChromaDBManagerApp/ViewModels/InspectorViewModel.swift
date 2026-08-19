import Foundation
import SwiftUI
import ChromaCore

/// Экран инспектора здоровья коллекции и обзора её состава.
///
/// Ничего не исправляет сам: каждая находка сопровождается предлагаемым
/// действием, и выполняет его человек — отдельно и с подтверждением.
@MainActor
final class InspectorViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case checks
        case overview
        case topics

        var id: String { rawValue }

        var title: String {
            switch self {
            case .checks: return String(localized: "Проверки")
            case .overview: return String(localized: "Обзор")
            case .topics: return String(localized: "Темы")
            }
        }
    }

    @Published var tab: Tab = .checks
    @Published var isRunning = false
    @Published var stage: String?
    @Published var progress: Double?
    @Published var report: InspectionReport?
    @Published var comparison: InspectionComparison?
    @Published var history: [InspectionReport] = []
    @Published var overview: CollectionOverview?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var expanded: Set<InspectionCategory> = []
    @Published var selectedFindings: Set<String> = []

    /// Дорогая проверка — отдельной галочкой, выключенной.
    @Published var checksNearDuplicates = false
    /// Проверять, что файлы источников ещё на месте.
    ///
    /// Выключено по умолчанию и включается руками: это обход папок всех
    /// источников коллекции, а на отключённом диске «файла нет» значит совсем
    /// не то, что после переименования папки.
    @Published var checksFilesOnDisk = false
    @Published var sampleSize = 5000
    @Published var nearDuplicateSampleSize = 1000

    // MARK: - Темы

    @Published var topicReport: TopicReport?
    @Published var topicHistory: [TopicReport] = []
    /// по умолчанию до 10 000 документов.
    @Published var topicSampleSize = 10_000
    /// Число тем подбирается само, пока человек не задал своё.
    @Published var picksClusterCountAutomatically = true
    @Published var clusterCount = 8
    @Published var namesTopics = true
    @Published var topicModel = ""
    @Published var chatModels: [LMStudioModel] = []

    private let store = InspectionStore()
    private let topics = TopicReportStore()
    private var task: Task<Void, Never>?

    func prepare(for collection: ChromaCollection) {
        history = store.reports(for: collection.name)
        report = history.first
        comparison = InspectionComparison.between(history.first ?? InspectionReport(collectionName: collection.name), and: history.dropFirst().first)
        overview = nil
        errorMessage = nil
        statusMessage = nil
        selectedFindings = []
        topicHistory = topics.reports(for: collection.name)
        topicReport = topicHistory.first
        if let model = topicReport?.namingModel, topicModel.isEmpty { topicModel = model }
    }

    /// Список чат-моделей — отдельно и не блокируя, как на экране оценки:
    /// запрос к LM Studio встаёт в очередь за работающим эмбеддингом, и ждать
    /// его, чтобы показать вкладку, незачем.
    func loadChatModels(app: AppEnvironment) {
        guard chatModels.isEmpty else { return }
        Task { [weak self] in
            guard let lmStudio = try? app.makeLMStudioClient(),
                  let loaded = try? await lmStudio.models()
            else { return }
            await MainActor.run {
                guard let self else { return }
                self.chatModels = ModelPickerOrder.sorted(loaded, preferring: .chat)
                if self.topicModel.isEmpty {
                    self.topicModel = self.chatModels.first { $0.kind == .chat }?.id ?? ""
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        stage = nil
    }

    // MARK: - Прогон

    func run(collection: ChromaCollection, app: AppEnvironment) {
        guard let client = app.client else {
            errorMessage = String(localized: "Нет подключения к ChromaDB.")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        statusMessage = nil
        progress = nil

        let options = InspectionOptions(
            sampleSize: sampleSize,
            checksNearDuplicates: checksNearDuplicates,
            nearDuplicateSampleSize: nearDuplicateSampleSize
        )
        let knownSourceIDs = Set(app.settings.configuration.dataSources.map(\.id.uuidString))
        let schema = app.schemaStore.schema(for: collection.name)
        let acknowledged = store.acknowledgedPairs(for: collection.name)
        let sources = app.settings.configuration.dataSources
        let wantsFileCheck = checksFilesOnDisk
        let previous = store.reports(for: collection.name).first

        task = Task { [weak self] in
            // Одна ссылка на всю задачу вместо «weak self» в каждом вложенном
            // замыкании. Перезахват внешней переменной из параллельно
            // исполняемого кода — это гонка, и компилятор о ней предупреждает;
            // здесь же `self` становится неизменяемой связкой, а вложенные
            // замыкания либо берут её как есть, либо — там, где замыкание
            // переживает задачу, — снова слабо, но уже от константы.
            guard let self else { return }
            do {
                // Спрашивается только если попросили: это обход папок всех
                // источников коллекции. Папка, которую прочитать
                // не удалось, в набор не попадает вовсе — «не знаем» честнее,
                // чем «файлов нет».
                var filesOnDisk: [String: Set<String>]?
                if wantsFileCheck {
                    var collected: [String: Set<String>] = [:]
                    for source in sources where !source.isWeb {
                        // Только источники, которые пишут **в эту** коллекцию:
                        // обходить папки всех двадцати ради проверки одной
                        // коллекции — это минуты ожидания вместо секунд.
                        //
                        // Спрашивается и манифест, и настройка источника.
                        // Одного манифеста мало: перенос настроек несёт
                        // источники, но не манифесты (SettingsTransfer), — на
                        // второй машине с общей базой манифест пуст, а чанки
                        // в коллекции есть, и молчать про них значит выключить
                        // проверку ровно там, где она нужнее всего.
                        //
                        // Сначала имя из настроек, и только потом манифест:
                        // манифест — это чтение и разбор JSON, который у папки
                        // на тысячи файлов весит мегабайты, а у самого частого
                        // режима («папка → одна коллекция») ответ виден
                        // из настройки бесплатно.
                        let named = CollectionNaming.sanitize(source.collectionName)
                        if named != collection.name {
                            let manifest = await app.syncService.manifest(for: source.id)
                            guard manifest.collections.contains(collection.name) else { continue }
                        }
                        guard let files = try? await app.syncService.scanFiles(source: source) else { continue }
                        let paths = Set(files.map { SourceSyncService.relative($0, to: source.url) })
                        // Пустая папка — это «не знаем», а не «файлы удалены»:
                        // так выглядит и вынесенная на время папка, и суженная
                        // маска расширений. Объявлять из-за неё исчезнувшей всю
                        // коллекцию нельзя (то же правило, что у порога
                        // массовой пропажи в).
                        guard !paths.isEmpty else { continue }
                        collected[source.id.uuidString] = paths
                    }
                    filesOnDisk = collected
                }
                let context = CollectionInspector.Context(
                    collection: collection,
                    knownSourceIDs: knownSourceIDs,
                    schema: schema,
                    acknowledgedPairs: acknowledged,
                    filesOnDisk: filesOnDisk
                )
                // инспектор читает базу и никого не заставляет считать
                // векторы — поэтому группа `database`, а не `lmStudio`.
                let produced = try await app.queue.run(QueueTicket(
                    title: String(localized: "Инспекция «\(collection.name)»"),
                    priority: .manual,
                    group: .database,
                    connectionID: app.connectionID
                )) { queueContext in
                    // Отменялку очередь хранит у себя, и она может пережить
                    // саму задачу — поэтому здесь ссылка слабая.
                    await app.queue.setCanceller(for: queueContext.id) { [weak self] in
                        Task { @MainActor in self?.cancel() }
                    }
                    return try await CollectionInspector(reader: client, log: app.logHandler).inspect(
                        context: context,
                        options: options,
                        progress: { done, total, stage in
                            Task { @MainActor in
                                self.stage = stage
                                self.progress = total > 0 ? Double(done) / Double(total) : nil
                            }
                            Task { await queueContext.report(progress: total > 0 ? Double(done) / Double(total) : nil, detail: stage) }
                        }
                    )
                }
                self.store.record(produced)
                await MainActor.run {
                    self.report = produced
                    self.comparison = InspectionComparison.between(produced, and: previous)
                    self.history = self.store.reports(for: collection.name)
                    self.statusMessage = produced.line
                    self.isRunning = false
                    self.stage = nil
                }
            } catch is CancellationError {
                await MainActor.run { self.isRunning = false; self.stage = nil }
            } catch {
                await MainActor.run {
                    self.errorMessage = app.describe(error)
                    self.isRunning = false
                    self.stage = nil
                }
            }
        }
    }

    func loadOverview(collection: ChromaCollection, app: AppEnvironment) {
        guard let client = app.client, !isRunning else { return }
        isRunning = true
        errorMessage = nil
        let extra = app.schemaStore.schema(for: collection.name)?.fields.map(\.trimmedKey) ?? []
        let size = sampleSize

        task = Task { [weak self] in
            guard let self else { return }
            do {
                // Через очередь, а не мимо неё. Обзор читает выборку
                // постранично — на пяти тысячах документов это десятки
                // запросов и секунды работы базы. Первая редакция звала
                // построитель напрямую: операция шла, а на экране «Задачи» её
                // не было, и отменить её оттуда было нечем. Модель обзор не
                // занимает, поэтому группа `database`.
                let built = try await app.queue.run(QueueTicket(
                    title: String(localized: "Обзор «\(collection.name)»"),
                    priority: .manual,
                    group: .database,
                    connectionID: app.connectionID
                )) { queueContext in
                    await app.queue.setCanceller(for: queueContext.id) { [weak self] in
                        Task { @MainActor in self?.cancel() }
                    }
                    return try await CollectionFacetBuilder(reader: client).overview(
                        collection: collection, sampleSize: size, extraFields: extra,
                        progress: { done, total in
                            Task { @MainActor in
                                self.stage = String(localized: "Чтение выборки")
                                self.progress = total > 0 ? Double(done) / Double(total) : nil
                            }
                            Task {
                                await queueContext.report(
                                    progress: total > 0 ? Double(done) / Double(total) : nil,
                                    detail: String(localized: "документов \(done.plainDigits)")
                                )
                            }
                        }
                    )
                }
                await MainActor.run {
                    self.overview = built
                    self.isRunning = false
                    self.stage = nil
                }
            } catch is CancellationError {
                await MainActor.run { self.isRunning = false; self.stage = nil }
            } catch {
                await MainActor.run {
                    self.errorMessage = app.describe(error)
                    self.isRunning = false
                    self.stage = nil
                }
            }
        }
    }

    // MARK: - Темы

    /// Прогон кластеризации.
    ///
    /// Реализовано по прямому согласию пользователя и ровно в тех
    /// границах, в которых оно дано: получается **список тем с числами и
    /// примерами**. Ни здесь, ни во вкладке нет проекции векторов на плоскость
    /// — запрет 6.4 и L5 в силе.
    func runTopics(collection: ChromaCollection, app: AppEnvironment) {
        guard let client = app.client else {
            errorMessage = String(localized: "Нет подключения к ChromaDB.")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        statusMessage = nil
        progress = nil

        let options = TopicClustering.Options(
            sampleSize: topicSampleSize,
            clusterCount: picksClusterCountAutomatically ? nil : clusterCount
        )
        let model = topicModel.trimmingCharacters(in: .whitespaces)
        let wantsNames = namesTopics && !model.isEmpty
        let lmStudio = wantsNames ? try? app.makeLMStudioClient() : nil
        if namesTopics && lmStudio == nil {
            // Правило 2 приложения 5: молча обойтись без названий нельзя.
            statusMessage = String(localized: "Названия тем не запрашиваются: чат-модель не выбрана или LM Studio недоступна. Темы будут пронумерованы.")
        }

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let produced = try await app.queue.run(QueueTicket(
                    title: String(localized: "Темы «\(collection.name)»"),
                    priority: .manual,
                    // Называние занимает локальную модель — и очередь обязана
                    // знать об этом заранее. Без названий это чистое
                    // чтение базы.
                    group: lmStudio == nil ? .database : .lmStudio,
                    connectionID: app.connectionID
                )) { queueContext in
                    await app.queue.setCanceller(for: queueContext.id) { [weak self] in
                        Task { @MainActor in self?.cancel() }
                    }
                    let namer: (model: String, call: TopicClustering.Namer)?
                    if let lmStudio {
                        namer = (model, { prompt, schema in
                            // temperature 0 и фиксированное зерно —
                            // названия тем не должны меняться от прогона
                            // к прогону сами по себе.
                            try await lmStudio.complete(
                                prompt: prompt, model: model,
                                settings: ChatGenerationSettings(), schema: schema,
                                timeout: TopicClustering.namingTimeout
                            )
                        })
                    } else {
                        namer = nil
                    }
                    return try await TopicClustering(reader: client, log: app.logHandler).run(
                        collection: collection,
                        options: options,
                        namer: namer,
                        progress: { update in
                            Task { @MainActor in
                                self.stage = update.stage
                                self.progress = update.total > 0 ? Double(update.done) / Double(update.total) : nil
                            }
                            Task {
                                await queueContext.report(
                                    progress: update.total > 0 ? Double(update.done) / Double(update.total) : nil,
                                    detail: update.stage
                                )
                            }
                        }
                    )
                }
                self.topics.record(produced)
                await MainActor.run {
                    self.topicReport = produced
                    self.topicHistory = self.topics.reports(for: collection.name)
                    self.statusMessage = produced.line
                    self.isRunning = false
                    self.stage = nil
                }
            } catch is CancellationError {
                await MainActor.run { self.isRunning = false; self.stage = nil }
            } catch {
                await MainActor.run {
                    self.errorMessage = app.describe(error)
                    self.isRunning = false
                    self.stage = nil
                }
            }
        }
    }

    func exportTopics(markdown: Bool, app: AppEnvironment) {
        guard let topicReport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "topics-\(topicReport.collectionName)\(markdown ? ".md" : ".json")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = markdown
                ? Data(TopicExport.markdown(topicReport).utf8)
                : try TopicExport.json(topicReport)
            try data.write(to: url, options: .atomic)
            statusMessage = String(localized: "Отчёт сохранён: \(url.lastPathComponent)")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    // MARK: - Действия по находкам

    func toggle(_ category: InspectionCategory) {
        if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
    }

    /// Находки, которые вообще можно выбрать.
    ///
    /// У части находок документов нет — это замечания «про коллекцию»,
    /// а не про записи; удалять и помечать в них нечего, и флажка у них
    /// в списке тоже нет. Кнопка «выбрать все» обязана считать так же,
    /// иначе она обещала бы то, чего не сделает.
    func selectable(in category: InspectionCategory? = nil) -> [InspectionFinding] {
        guard let report else { return [] }
        return report.findings.filter { finding in
            !finding.documentIDs.isEmpty && (category == nil || finding.category == category)
        }
    }

    /// Выбрано ли **всё** в этом разряде (или во всём отчёте).
    ///
    /// «Всё», а не «хоть что-то»: иначе кнопка предлагала бы снять выбор
    /// сразу после первого флажка, и выбрать разряд целиком было бы нечем
    /// (та же ошибка, что чинил на экране диагностики).
    func isEverythingSelected(in category: InspectionCategory? = nil) -> Bool {
        let all = selectable(in: category)
        return !all.isEmpty && all.allSatisfy { selectedFindings.contains($0.id) }
    }

    /// Переключает разряд целиком: выбранное снимает, невыбранное добавляет.
    /// Возвращает, выбран ли разряд после нажатия, — экрану это нужно, чтобы
    /// раскрыть список: выбор, которого не видно, бесполезен.
    @discardableResult
    func toggleSelection(in category: InspectionCategory? = nil) -> Bool {
        let all = selectable(in: category)
        guard !all.isEmpty else { return false }
        let ids = all.map(\.id)
        if isEverythingSelected(in: category) {
            selectedFindings.subtract(ids)
            return false
        }
        selectedFindings.formUnion(ids)
        return true
    }

    func toggleSelection(_ finding: InspectionFinding) {
        if selectedFindings.contains(finding.id) {
            selectedFindings.remove(finding.id)
        } else {
            selectedFindings.insert(finding.id)
        }
    }

    /// Документы, которых коснётся удаление. Показываются **до** него: правило 3
    /// приложения 5 — сначала список, потом действие.
    func selectedDocumentIDs() -> [String] {
        guard let report else { return [] }
        let chosen = report.findings.filter { selectedFindings.contains($0.id) }
        return Array(Set(chosen.flatMap(\.documentIDs))).sorted()
    }

    /// Удаление — с копией в корзину, как и всякое ручное удаление
    /// документа в этом приложении.
    func deleteSelected(collection: ChromaCollection, app: AppEnvironment) {
        let ids = selectedDocumentIDs()
        guard !ids.isEmpty, let client = app.client else { return }
        isRunning = true
        task = Task { [weak self] in
            do {
                if app.settings.configuration.trashEnabled {
                    let records = try await client.getDocuments(collectionID: collection.id, limit: ids.count, ids: ids)
                    let vectors = try await client.embeddings(collectionID: collection.id, ids: ids)
                    // Одной пачкой, а не по документу за раз: захват — это
                    // всё или ничего. Поштучная запись на середине отказа
                    // оставила бы половину копий в корзине от удаления,
                    // которого не было.
                    let batch = records.map { record in
                        TrashEntry(
                            documentID: record.id,
                            document: record.document,
                            metadata: record.metadata,
                            embedding: vectors[record.id],
                            collectionName: collection.name,
                            collectionMetric: collection.space,
                            collectionModel: collection.boundModel,
                            collectionDimension: collection.effectiveDimension,
                            reason: .document
                        )
                    }
                    // Бросит, если копии не легли на диск, — и удаление ниже
                    // тогда не выполнится.
                    try app.trash.record(batch)
                }
                try await client.deleteDocuments(collectionID: collection.id, ids: ids)
                await MainActor.run {
                    guard let self else { return }
                    // Отчёт после удаления перестаёт быть правдой — и делать
                    // вид, что он ещё описывает коллекцию, нельзя.
                    self.report = nil
                    self.selectedFindings = []
                    self.isRunning = false
                    self.statusMessage = app.settings.configuration.trashEnabled
                        ? String(localized: "Удалено документов: \(ids.count.plainDigits); копии — в корзине. Прогоните инспектор заново.")
                        : String(localized: "Удалено документов: \(ids.count.plainDigits). Прогоните инспектор заново.")
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = app.describe(error)
                    self?.isRunning = false
                }
            }
        }
    }

    /// Есть ли что чинить уборкой путей.
    var hasLegacyPaths: Bool {
        report?.findings.contains { $0.category == .legacyFilePaths } ?? false
    }

    /// Привести пути к единой форме и проставить отпечатки.
    ///
    /// По всей коллекции, а не по выделенному: инспектор смотрит выборку,
    /// а чинить половину коллекции — значит оставить ту же беду на второй
    /// половине и не сказать об этом. Меняются только метаданные: текст
    /// не трогается, векторы не пересчитываются.
    func repairFilePaths(collection: ChromaCollection, app: AppEnvironment) {
        guard let client = app.client else { return }
        isRunning = true
        task = Task { [weak self] in
            do {
                var offset = 0
                var chunks = 0
                var files: Set<String> = []
                while true {
                    try Task.checkCancellation()
                    let page = try await client.getDocuments(
                        collectionID: collection.id, limit: Self.repairPageSize, offset: offset
                    )
                    guard !page.isEmpty else { break }
                    offset += page.count

                    let updates = FilePathRepair.updates(for: page)
                    if !updates.isEmpty {
                        try await client.updateDocuments(collectionID: collection.id, updates: updates)
                        chunks += updates.count
                        for record in page where FilePathRepair.needsRepair(record.metadata) {
                            if let path = FilePathRepair.filePath(record.metadata) {
                                files.insert(FilePathKey.canonical(path))
                            }
                        }
                    }
                    await MainActor.run {
                        self?.statusMessage = String(localized: "Просмотрено чанков: \(offset.plainDigits), переписано: \(chunks.plainDigits)")
                    }
                    if page.count < Self.repairPageSize { break }
                }

                let updated = chunks
                let fileCount = files.count
                await MainActor.run {
                    guard let self else { return }
                    // Отчёт составлялся до уборки — оставлять его значит
                    // показывать находки, которых больше нет.
                    self.report = nil
                    self.selectedFindings = []
                    self.isRunning = false
                    self.statusMessage = updated == 0
                        ? String(localized: "Пути уже в единой форме — переписывать нечего.")
                        : String(localized: "Пути приведены к единой форме: файлов \(fileCount.plainDigits), чанков \(updated.plainDigits). Векторы не пересчитывались. Прогоните инспектор заново.")
                    app.log.record(.success, "Коллекции",
                                   "Коллекция «\(collection.name)»: пути приведены к единой форме у \(updated.plainDigits) чанков (\(fileCount.plainDigits) файлов), векторы не пересчитывались")
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = app.describe(error)
                    self?.isRunning = false
                }
            }
        }
    }

    /// Сколько чанков читается за раз при уборке путей.
    private static let repairPageSize = 500

    /// «Это не дубли» — пара больше не всплывает.
    func acknowledgeSelectedPairs(collection: ChromaCollection) {
        guard let report else { return }
        let pairs = report.findings
            .filter { selectedFindings.contains($0.id) && $0.category == .nearDuplicates }
            .map(\.subject)
        guard !pairs.isEmpty else { return }
        store.acknowledge(pairs: pairs, collection: collection.name)
        selectedFindings = []
        statusMessage = String(localized: "Помечено как проверенное: \(pairs.count.plainDigits). В следующих прогонах эти пары не появятся.")
    }

    func forgetAcknowledged(collection: ChromaCollection) {
        store.forgetAcknowledged(collection: collection.name)
        statusMessage = String(localized: "Отметки «это не дубли» сняты — в следующем прогоне пары покажутся снова.")
    }

    /// Разрывы в нумерации чинит синхронизация: файл забывается в манифесте,
    /// и следующий прогон источника записывает его заново. Базу это не трогает
    /// вовсе — меняется только наша собственная запись о том, что уже сделано.
    func forgetInManifest(file: String, app: AppEnvironment) {
        task = Task { [weak self] in
            for source in app.settings.configuration.dataSources {
                var manifest = await app.syncService.manifest(for: source.id)
                guard manifest.entries[file] != nil else { continue }
                manifest.forget(relativePath: file)
                await app.syncService.save(manifest: manifest)
                await MainActor.run {
                    self?.statusMessage = String(localized: "Файл «\(file)» забыт в манифесте источника «\(source.name)» — следующая синхронизация запишет его заново. Сама она не запустится.")
                }
                return
            }
            await MainActor.run {
                self?.errorMessage = String(localized: "Файл «\(file)» не нашёлся ни в одном источнике: скорее всего, его чанки пришли не из синхронизации.")
            }
        }
    }

    // MARK: - Экспорт

    func export(markdown: Bool, app: AppEnvironment) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "inspection-\(report.collectionName)\(markdown ? ".md" : ".json")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = markdown
                ? Data(InspectionExport.markdown(report, comparison: comparison).utf8)
                : try InspectionExport.json(report)
            try data.write(to: url, options: .atomic)
            statusMessage = String(localized: "Отчёт сохранён: \(url.lastPathComponent)")
        } catch {
            errorMessage = app.describe(error)
        }
    }
}
