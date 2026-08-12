import Foundation
import SwiftUI
import ChromaCore

/// Data sources on the «Эмбеддинги» tab: registration, mapping, chunking
/// parameters and manual synchronisation (substage 2C).
@MainActor
final class SourcesViewModel: ObservableObject {
    // Editing
    @Published var draft: DataSource?
    @Published var draftIsNew = false
    @Published var draftMetadataRows: [MetadataRow] = []
    @Published var draftSeparators = ""

    // Running state
    /// Источники, которые сейчас синхронизируются или ждут своей очереди
    ///.
    ///
    /// Раньше здесь был **один** источник, и панель запрещала второй запуск,
    /// пока идёт первый: человек, у которого папок много, вынужден был сидеть
    /// у компьютера и нажимать следующую, как только освободится модель.
    /// Очередь и без того пускает к локальной модели по одной задаче за раз —
    /// значит запрет ничего не защищал, а только заставлял ждать у экрана.
    @Published var busySourceIDs: Set<UUID> = []
    /// How many operations are in flight.
    ///
    /// Raised **the instant a button is pressed**, not when the work reaches the
    /// service. `busySourceID` alone could not do that job: a manual sync first
    /// builds a plan — reading and hashing every file of the folder — and only
    /// then enters `run`, which is where the source id used to be set. For those
    /// seconds `isBusy` answered «нет», every button in the panel stayed enabled
    /// and `guard !isBusy` guarded nothing, so a second press started a second
    /// concurrent run over the same model — and `task` then pointed at the newer
    /// one, leaving «Отменить» unable to stop the older.
    ///
    /// A counter rather than a flag because operations nest: «Синхронизировать
    /// все» is one operation around a loop of runs, and each run raises it too.
    @Published private(set) var operationCount = 0
    /// Why the current run started — shown so an automatic sync is never silent.
    @Published var activeReason: SyncReason?
    /// Идёт ли обход всего списка. Второй такой запуск запрещён, а вот
    /// отдельные источники ставить в очередь можно и во время него.
    @Published private(set) var isSyncingAll = false
    @Published var lastSummary: SyncSummary?
    /// Файлы и папки, которые перетащили на окно или на значок в Dock.
    /// Экран источников спрашивает, что с ними делать.
    @Published var pendingDrop: [URL] = []
    /// План на источник, а не один на экран. Двух планов на экране
    /// быть не могло: поставив вторую папку, человек видел только её план, а
    /// первый молча исчезал вместе с ответом на вопрос «что она затронет».
    @Published var plans: [UUID: SyncPlan] = [:]
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    // sync preview
    /// Files unchecked in the plan — excluded from the next run of that
    /// source. Cleared whenever a fresh plan replaces the one it applied to.
    @Published var excludedPaths: [UUID: Set<String>] = [:]
    /// Set when a manual sync's scope crossed the threshold and is waiting for
    /// an explicit "Подтвердить" rather than running straight away (rule 4,
    /// Приложение 5). План этого источника показывается, пока он здесь.
    @Published var pendingConfirmations: Set<UUID> = []
    /// Snapshotted alongside `lastPlan` — `MetricsStore` is an actor, and the
    /// plan card reads this synchronously while drawing.
    @Published var lastPlanMetrics = MetricsSnapshot()
    /// Measured model speeds: what the estimate falls back to when a
    /// model has never done real work — the case J2's estimate had to stay
    /// silent about until now.
    @Published var lastPlanBenchmarks: [ModelBenchmark] = []

    /// Manifest facts shown on each card, refreshed after every sync.
    @Published var manifestInfo: [UUID: ManifestInfo] = [:]
    /// Источники, для которых манифест **уже прочитан**. Без этого отсутствие
    /// записи означало сразу и «ещё не читали», и «прочитали, там пусто», —
    /// и карточка печатала «ещё не синхронизирован» про источник, о котором
    /// ничего не знала.
    @Published var manifestsRead: Set<UUID> = []
    @Published var pendingRemovals: [UUID: [PendingRemoval]] = [:]
    /// rows indexed from tables, per source. The file manifest knows
    /// nothing about them — a source of spreadsheets would otherwise report
    /// «ещё не синхронизирован» after indexing thousands of rows.
    @Published var tableRows: [UUID: Int] = [:]
    /// Сколько файлов-таблиц у источника. Строки живут в своём манифесте, но
    /// сами таблицы — такие же файлы в папке, и в счёт файлов они входят
    ///.
    @Published var tableFiles: [UUID: Int] = [:]
    /// files an older version of the extractor produced. Learned from the
    /// last plan or run of a source and shown until something is done about it —
    /// the app never puts them in a queue by itself.
    @Published var staleExtraction: [UUID: [StaleExtraction]] = [:]
    /// the diagnostics screen. Files the last run could not read, and
    /// files it read with something to say about them.
    @Published var problems: [UUID: [FileProblem]] = [:]
    @Published var warnedFiles: [UUID: [ManifestEntry]] = [:]
    @Published var showingDiagnostics = false
    /// set when the pending run would send a lot of rows to the model.
    /// The sample-run offer is shown only while this is set.
    @Published var tableEstimates: [UUID: TableRunEstimate] = [:]
    /// How many rows a trial run writes.
    @Published var sampleRowCount = 200

    /// the source whose table mapping is being edited.
    @Published var tableMappingSource: UUID?
    let tableMapping = TableMappingViewModel()
    /// The file a password is being typed for, and the field it is typed into.
    /// The value never leaves this object for anywhere but the Keychain.
    @Published var passwordFor: (sourceID: UUID, relativePath: String)?
    @Published var passwordInput = ""

    var problemCount: Int { problems.values.reduce(0) { $0 + $1.count } }
    var warnedFileCount: Int { warnedFiles.values.reduce(0) { $0 + $1.count } }

    /// По задаче на источник: «Остановить» у карточки обязано снимать **её**
    /// работу, а не последнюю начатую. Ключ `Self.wholeList` — у
    /// операций, которые про весь список сразу.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private static let wholeList = UUID()
    /// Set once by `AutoSyncCoordinator`: how to stop a run that a timer, the
    /// launch trigger or a folder watcher started.
    var cancelAutomaticWork: (() -> Void)?

    /// Состояние карточки: прочитан ли манифест и что в нём.
    func syncStatus(of sourceID: UUID) -> SourceSyncStatus {
        guard manifestsRead.contains(sourceID) else { return .unknown }
        let info = manifestInfo[sourceID].map { (files: $0.files, chunks: $0.chunks, updatedAt: $0.updatedAt) }
        return SourceSyncStatus.of(
            info: info,
            tableRows: tableRows[sourceID] ?? 0,
            tableFiles: tableFiles[sourceID] ?? 0
        )
    }

    struct ManifestInfo {
        let files: Int
        let chunks: Int
        let collections: [String]
        let updatedAt: Date?
    }

    /// Что git думает о каждом источнике-репозитории. Спрашивается при
    /// открытии экрана и после синхронизации: сам по себе этот вопрос ничего
    /// не индексирует.
    @Published var gitStatus: [UUID: GitSyncService.Status] = [:]
    /// Источники, которым автоматические режимы больше не доверяют: прошлое
    /// восстановление после обрыва не доигралось. Ядро блокирует их само
    ///, но до этого экран об этом молчал, и человек видел лишь то, что
    /// расписание перестало работать.
    @Published var recoveryBlocks: [UUID: String] = [:]

    struct MetadataRow: Identifiable, Hashable {
        let id = UUID()
        var key: String = ""
        var value: String = ""
    }

    /// True from the press of the button to the end of the work it started.
    var isBusy: Bool { operationCount > 0 || !busySourceIDs.isEmpty }

    /// Занят ли **этот** источник. Запрещать второй запуск нужно только ему:
    /// остальные встают в очередь и ждут там.
    func isBusy(_ sourceID: UUID) -> Bool { busySourceIDs.contains(sourceID) }

    /// Claims the panel for an operation. Call **synchronously** from the action
    /// that starts it, before the first `await` — that is the whole point.
    private func beginOperation() { operationCount += 1 }

    private func endOperation() { operationCount = max(0, operationCount - 1) }

    // MARK: - Registration

    func addSource(_ app: AppEnvironment) {
        guard let url = ConnectionViewModel.chooseDirectory(
            title: "Выберите папку с документами",
            message: "Файлы из этой папки будут разбиты на чанки и проиндексированы в коллекцию."
        ) else { return }

        let name = url.lastPathComponent
        let source = DataSource(
            name: name,
            path: url.path,
            // Всё, что приложение умеет читать. Папку добавляют, чтобы её
            // проиндексировали, а «md, txt» тихо оставляли за бортом остальное:
            // список виден в поле и сокращается одним движением, а вот заметить
            // недостающее расширение можно было только по отсутствию документов.
            fileExtensions: TextExtractor.supportedExtensions,
            recursive: true,
            mapping: .folderToCollection,
            collectionName: CollectionNaming.sanitize(name),
            embeddingModel: app.settings.configuration.defaultEmbeddingModel
        )
        beginEditing(source, isNew: true)
    }

    /// Репозиторий. Это та же папка, просто про неё есть кому
    /// рассказать больше — поэтому и выбирается она так же.
    func addGitSource(_ app: AppEnvironment) {
        guard let url = ConnectionViewModel.chooseDirectory(
            title: "Выберите рабочую копию репозитория",
            message: "Список файлов даст git: в индекс не попадут ни .git, ни то, что перечислено в .gitignore."
        ) else { return }

        let name = url.lastPathComponent
        let source = DataSource(
            name: name,
            path: url.path,
            fileExtensions: TextExtractor.supportedExtensions,
            recursive: true,
            mapping: .singleCollectionWithRelativePath,
            collectionName: CollectionNaming.sanitize(name),
            embeddingModel: app.settings.configuration.defaultEmbeddingModel,
            git: GitSourceSettings()
        )
        beginEditing(source, isNew: true)
    }

    /// Веб-источник. Папку выбирают в окне выбора файлов, а адрес
    /// вводят руками — поэтому здесь сразу открывается редактор с пустым
    /// адресом, а не диалог.
    func addWebSource(_ app: AppEnvironment) {
        let source = DataSource(
            name: String(localized: "Новый веб-источник"),
            path: "",
            fileExtensions: [],
            recursive: false,
            mapping: .folderToCollection,
            collectionName: "web",
            embeddingModel: app.settings.configuration.defaultEmbeddingModel,
            web: WebSourceSettings()
        )
        beginEditing(source, isNew: true)
    }

    /// Открывает редактор источника для папки, которую перетащили.
    ///
    /// Ровно тот же черновик, что у «Добавить папку»: перетаскивание — это
    /// другой способ назвать папку, а не другой способ её завести. Папок
    /// может быть несколько, но редактор один — берётся первая, остальные
    /// ждут своей очереди в `pendingDrop`.
    func beginEditingDroppedFolder(_ app: AppEnvironment) {
        guard draft == nil, let url = pendingDrop.first else { return }
        pendingDrop.removeFirst()
        let name = url.lastPathComponent
        beginEditing(DataSource(
            name: name,
            path: url.path,
            fileExtensions: TextExtractor.supportedExtensions,
            recursive: true,
            mapping: .folderToCollection,
            collectionName: CollectionNaming.sanitize(name),
            embeddingModel: app.settings.configuration.defaultEmbeddingModel
        ), isNew: true)
    }

    func beginEditing(_ source: DataSource, isNew: Bool = false) {
        draft = source
        draftIsNew = isNew
        draftMetadataRows = source.customMetadata.keys.sorted().map {
            MetadataRow(key: $0, value: source.customMetadata[$0] ?? "")
        }
        if draftMetadataRows.isEmpty { draftMetadataRows = [MetadataRow()] }
        draftSeparators = source.chunking.separators
            .map { $0.replacingOccurrences(of: "\n", with: "\\n") }
            .joined(separator: " | ")
    }

    func saveDraft(_ app: AppEnvironment) {
        guard var source = draft else { return }
        source.collectionName = CollectionNaming.sanitize(source.collectionName)
        // У веб-источника «путь» — это его адрес: он показывается в списке,
        // в логе и в сводке, и расходиться с настройкой ему нельзя.
        if var web = source.web {
            web.startURL = web.startURL.trimmingCharacters(in: .whitespacesAndNewlines)
            web.additionalURLs = web.additionalURLs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            web.extraHosts = web.extraHosts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            source.web = web
            source.path = web.startURL
        }
        source.fileExtensions = source.fileExtensions
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty }
        source.customMetadata = Dictionary(
            draftMetadataRows
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { _, last in last }
        )
        source.chunking.separators = Self.parseSeparators(draftSeparators, fallback: source.chunking.separators)

        app.settings.upsert(source: source)
        app.log.record(
            .info,
            "Источники",
            "\(draftIsNew ? "Добавлен" : "Изменён") источник «\(source.name)»: \(source.mapping.title), \(source.chunking.summaryText)"
        )
        draft = nil
        refreshManifests(app)
    }

    func cancelDraft() { draft = nil }

    // MARK: - Diagnostics actions

    /// «Повторить» is an ordinary sync: a file that failed has no manifest entry,
    /// so the next run tries it again by itself. Everything that did read stays
    /// read — the manifest is what makes that cheap.
    func retry(_ source: DataSource, app: AppEnvironment) {
        showingDiagnostics = false
        sync(source, app: app)
    }

    func enableOCR(for source: DataSource, app: AppEnvironment) {
        guard !source.ocrEnabled else { return }
        var updated = source
        updated.ocrEnabled = true
        app.settings.upsert(source: updated)
        app.log.record(.info, "Источники", "Источник «\(source.name)»: включено распознавание (OCR) из диагностики")
        // Not started here: recognising a folder of scans is minutes to hours of
        // work, and rule 4 of Приложение 5 says the user starts it.
        infoMessage = String(localized: "Распознавание включено для источника «\(source.name)». Запустите синхронизацию, когда будете готовы: распознавание идёт заметно дольше обычного чтения.")
        refreshManifests(app)
    }

    /// Stop trying to read this file. Not a deletion: if it is already in the
    /// collection it turns up as «требует решения» on the next run, and the user
    /// decides what happens to its chunks (rule 1 of Приложение 5).
    func exclude(_ relativePath: String, in source: DataSource, app: AppEnvironment) {
        guard !source.excludedPaths.contains(relativePath) else { return }
        var updated = source
        updated.excludedPaths.append(relativePath)
        app.settings.upsert(source: updated)
        app.log.record(.warning, "Источники", "Источник «\(source.name)»: файл \(relativePath) исключён из индексации (документы в базе не тронуты)")
        problems[source.id]?.removeAll { $0.relativePath == relativePath }
        infoMessage = String(localized: "\(relativePath) больше не читается. Уже записанные чанки остались в базе — если файл там есть, следующий запуск предложит решить, что с ними делать.")
    }

    /// Undoing an exclusion: the file goes back into the source and the next run
    /// reads it like any other.
    func include(_ relativePath: String, in source: DataSource, app: AppEnvironment) {
        var updated = source
        updated.excludedPaths.removeAll { $0 == relativePath }
        app.settings.upsert(source: updated)
        app.log.record(.info, "Источники", "Источник «\(source.name)»: файл \(relativePath) снова индексируется")
    }

    func promptForPassword(_ problem: FileProblem, source: DataSource) {
        passwordInput = ""
        passwordFor = (source.id, problem.relativePath)
    }

    /// Straight into the Keychain and nowhere else (rule 7 of Приложение 5).
    func savePassword(_ app: AppEnvironment) {
        guard let target = passwordFor else { return }
        let password = passwordInput
        passwordInput = ""
        passwordFor = nil
        guard !password.isEmpty else { return }
        do {
            try app.documentPasswords.set(password, sourceID: target.sourceID, relativePath: target.relativePath)
            // The password itself is never logged, and neither is its length.
            app.log.record(.info, "Источники", "Сохранён пароль для файла \(target.relativePath) (в Keychain)")
            infoMessage = String(localized: "Пароль сохранён в Keychain. Запустите синхронизацию — файл будет прочитан с ним.")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    /// Источник, про который спрашивают «точно удалить?».
    ///
    /// Правило 3 приложения 5 — сначала список, потом действие. Кнопка-корзина
    /// стоит вплотную к «Синхронизировать», а промах стоит всей настройки
    /// источника: стратегию можно поднять из манифеста, а расписания, поля
    /// метаданных, профили таблиц и параметры нарезки — уже ниоткуда. Ровно это
    /// и выяснилось при восстановлении одиннадцати источников 9 августа
    ///.
    @Published var sourcePendingRemoval: DataSource?

    func removeSource(_ source: DataSource, app: AppEnvironment) {
        app.settings.removeSource(id: source.id)
        Task { await app.syncService.removeManifest(for: source.id) }
        manifestInfo[source.id] = nil
        manifestsRead.remove(source.id)
        tableFiles[source.id] = nil
        pendingRemovals[source.id] = nil
        app.log.record(.warning, "Источники", "Источник «\(source.name)» удалён из списка (документы в базе не тронуты)")
    }

    /// Separators are typed as one line, with `\n` spelled out: a text field
    /// cannot hold a real newline, and an invisible one is unreadable anyway.
    static func parseSeparators(_ text: String, fallback: [String]) -> [String] {
        let parts = text.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\\n", with: "\n") }
        return parts.isEmpty ? fallback : parts
    }

    // MARK: - Manifest facts

    func refreshManifests(_ app: AppEnvironment) {
        let sources = app.settings.configuration.dataSources
        Task { [weak self] in
            var info: [UUID: ManifestInfo] = [:]
            var pending: [UUID: [PendingRemoval]] = [:]
            var problems: [UUID: [FileProblem]] = [:]
            var warned: [UUID: [ManifestEntry]] = [:]
            var tableRowCounts: [UUID: Int] = [:]
            var tableFileCounts: [UUID: Int] = [:]
            var git: [UUID: GitSyncService.Status] = [:]
            var blocked: [UUID: String] = [:]
            for source in sources {
                // Спросить git — это два быстрых вызова и ноль записей в базу;
                // зато экран сразу знает про ветку и про то, что её сменили.
                if source.isGit { git[source.id] = await app.gitSync.status(of: source) }
                let manifest = await app.syncService.manifest(for: source.id)
                info[source.id] = ManifestInfo(
                    files: manifest.fileCount,
                    chunks: manifest.chunkCount,
                    collections: manifest.collections,
                    updatedAt: manifest.updatedAt
                )
                if !manifest.pendingRemovals.isEmpty { pending[source.id] = manifest.pendingRemovals }
                // Чтение манифеста таблиц — синхронное и с диска, а `Task`
                // модели экрана наследует главный актор: без ухода в сторону
                // двадцать источников читались главным потоком.
                let tables = await Task.detached(priority: .utility) { [store = app.tableManifests] in
                    store.load(sourceID: source.id)
                }.value
                let rows = tables.values.reduce(0) { $0 + $1.rowCount }
                if rows > 0 {
                    tableRowCounts[source.id] = rows
                    tableFileCounts[source.id] = tables.count
                }
                if !manifest.problems.isEmpty { problems[source.id] = manifest.problems.sorted { $0.relativePath < $1.relativePath } }
                let warnedEntries = manifest.warnedEntries
                if !warnedEntries.isEmpty { warned[source.id] = warnedEntries }
                if let reason = await app.syncService.recoveryBlockReason(sourceID: source.id) {
                    blocked[source.id] = reason
                }
            }
            await MainActor.run {
                guard let self else { return }
                // Слияние, а не присваивание. Обновлений шесть точек вызова,
                // все асинхронные, порядок завершения не определён — и прогон,
                // начатый со ещё не прочитанным списком источников, целиком
                // затирал факты обо всех остальных. Сливаем только то,
                // что этот прогон действительно посчитал.
                for source in sources {
                    self.manifestInfo[source.id] = info[source.id]
                    self.pendingRemovals[source.id] = pending[source.id]
                    self.problems[source.id] = problems[source.id]
                    self.warnedFiles[source.id] = warned[source.id]
                    self.tableRows[source.id] = tableRowCounts[source.id]
                    self.tableFiles[source.id] = tableFileCounts[source.id]
                    self.gitStatus[source.id] = git[source.id]
                    self.recoveryBlocks[source.id] = blocked[source.id]
                    self.manifestsRead.insert(source.id)
                }
            }
        }
    }

    // MARK: - Dry run

    /// Compares the folder with the manifest without embedding anything.
    func preview(_ source: DataSource, app: AppEnvironment) {
        guard !isBusy(source.id) else { return }
        let model = source.embeddingModel ?? app.settings.configuration.defaultEmbeddingModel ?? ""
        busySourceIDs.insert(source.id)
        errorMessage = nil
        infoMessage = nil
        lastSummary = nil
        pendingConfirmations.remove(source.id)
        excludedPaths[source.id] = []

        // Тем же тикетом, что и подготовка к синхронизации: обход папки виден
        // в «Задачах», пока он идёт.
        let planTicket = QueueTicket(
            title: String(localized: "План источника «\(source.name)»"),
            priority: .interactive,
            group: .filesystem,
            connectionID: app.connectionID
        )
        // Ссылки на службы берутся здесь, на главном потоке: замыкание задачи
        // исполняется вне его (та же причина, что и в `run`).
        let syncService = app.syncService
        let webSync = app.webSync
        let gitSync = app.gitSync
        tasks[source.id] = Task { [weak self] in
            do {
                let plan: SyncPlan = try await app.queue.run(planTicket) { _ in
                    if source.isWeb {
                        // Посмотреть на план веб-источника, не сходив в сеть,
                        // нельзя: страницы не лежат на диске. Загруженное тут же
                        // и выбрасывается — предпросмотр ничего не пишет.
                        let preparation = try await webSync.prepare(
                            source: source, embeddingModel: model,
                            manifest: syncService.manifest(for: source.id)
                        )
                        preparation.discardCache()
                        return preparation.plan
                    }
                    if source.isGit,
                       let preparation = try await gitSync.prepare(
                           source: source, embeddingModel: model,
                           manifest: syncService.manifest(for: source.id)
                       ),
                       preparation.degradedReason == nil {
                        return preparation.plan
                    }
                    return try await syncService.plan(source: source, embeddingModel: model)
                }
                let metrics = await app.metrics.current()
                let benchmarks = await app.benchmarks.all()
                await MainActor.run {
                    self?.plans[source.id] = plan
                    self?.lastPlanMetrics = metrics
                    self?.lastPlanBenchmarks = benchmarks
                    self?.staleExtraction[source.id] = plan.staleExtraction.isEmpty ? nil : plan.staleExtraction
                    self?.infoMessage = "План синхронизации «\(source.name)»: \(plan.summaryLine)."
                }
            } catch {
                await MainActor.run { self?.errorMessage = app.describe(error) }
            }
            await MainActor.run { self?.busySourceIDs.remove(source.id) }
            self?.refreshManifests(app)
        }
    }

    /// Chunk-count and time estimate for the currently shown plan — `nil`
    /// pieces mean no historical average exists yet (rule 4 Приложение 5:
    /// no guessed numbers).
    func estimate(for plan: SyncPlan, source: DataSource, app: AppEnvironment) -> (chunks: Int, time: SyncTimeEstimate?) {
        let model = source.embeddingModel ?? app.settings.configuration.defaultEmbeddingModel ?? ""
        let chunks = plan.estimatedChunkCount(chunking: source.chunking)
        let time = plan.estimatedDuration(
            chunking: source.chunking, embeddingModel: model,
            metrics: lastPlanMetrics, benchmarks: lastPlanBenchmarks
        )
        return (chunks, time)
    }

    func toggleExcluded(_ relativePath: String, in sourceID: UUID) {
        var paths = excludedPaths[sourceID] ?? []
        if paths.contains(relativePath) {
            paths.remove(relativePath)
        } else {
            paths.insert(relativePath)
        }
        excludedPaths[sourceID] = paths
    }

    func isExcluded(_ relativePath: String, in sourceID: UUID) -> Bool {
        excludedPaths[sourceID]?.contains(relativePath) ?? false
    }

    // MARK: - Sync

    /// The "Синхронизировать" button. Below the threshold this runs at once,
    /// like before J2; above it, the plan is shown and `confirmPendingSync`
    /// has to be called explicitly (rule 4, Приложение 5).
    func sync(_ source: DataSource, app: AppEnvironment) {
        // Запрещён только повтор **этого** источника: остальные встают в
        // очередь и ждут там своей очереди к модели.
        guard !isBusy(source.id) else { return }
        // Claimed here, not in `run`: between the press and `run` lies a full
        // plan of the folder, and for those seconds the panel used to look idle.
        beginOperation()
        busySourceIDs.insert(source.id)
        tasks[source.id] = Task { [weak self] in
            await self?.startManualSync(source, app: app)
            await MainActor.run {
                self?.endOperation()
                // The gate of J2 ends the operation without running anything;
                // the spinner has to go with it.
                self?.busySourceIDs.remove(source.id)
                self?.tasks[source.id] = nil
            }
        }
    }

    private func startManualSync(_ source: DataSource, app: AppEnvironment) async {
        let threshold = app.settings.configuration.syncPreviewThresholdFiles
        let model = source.embeddingModel ?? app.settings.configuration.defaultEmbeddingModel ?? ""
        // A cheap, read-only call purely for the gate — `sync()` re-plans
        // internally regardless, so this never risks disagreeing with it.
        //
        // Для веб-источника такого дешёвого плана не бывает: чтобы узнать, что
        // изменилось, надо сходить на сайт. Второй обход ради одной оценки —
        // это вдвое больше запросов к чужому серверу, поэтому воротами J2 здесь
        // служат ограничения обхода, которые человек задал сам.
        //
        // Обход папки — тоже задача очереди. Он идёт до всякой записи
        // и на большой папке занимает минуты: экран уже говорил «идёт
        // синхронизация», а в «Задачах» не было ничего — приложение выглядело
        // так, будто нажатие потерялось.
        let syncService = app.syncService
        let planned: SyncPlan?
        if source.isWeb {
            planned = nil
        } else {
            let ticket = QueueTicket(
                title: String(localized: "Подготовка синхронизации «\(source.name)»"),
                priority: .manual,
                group: .filesystem,
                connectionID: app.connectionID
            )
            planned = try? await app.queue.run(ticket) { _ in
                try await syncService.plan(source: source, embeddingModel: model)
            }
        }
        // a big sheet is hours of the local model, and the user has to
        // learn that **before** it starts. Rule 4 of Приложение 5 in its most
        // literal form — and the file-count threshold does not cover it: one
        // workbook is one file and fifty thousand calls.
        let bigTable = (planned?.tableRowsToEmbed ?? 0) > TableRunEstimate.warningThreshold
        if let plan = planned, plan.needsConfirmation(threshold: threshold) || bigTable {
            let metrics = await app.metrics.current()
            let benchmarks = await app.benchmarks.all()
            await MainActor.run {
                plans[source.id] = plan
                lastPlanMetrics = metrics
                lastPlanBenchmarks = benchmarks
                excludedPaths[source.id] = []
                pendingConfirmations.insert(source.id)
                if bigTable {
                    let estimate = TableRunEstimate(
                        embeddings: plan.tableRowsToEmbed, metadataWrites: 0,
                        seconds: secondsPerText(model, metrics: metrics, benchmarks: benchmarks)
                            .map { $0 * Double(plan.tableRowsToEmbed) },
                        basis: basis(model, metrics: metrics, benchmarks: benchmarks)
                    )
                    tableEstimates[source.id] = estimate
                    infoMessage = String(localized: "Строк из таблиц к обработке: \(plan.tableRowsToEmbed) — это \(plan.tableRowsToEmbed) обращений к модели. \(estimate.line). Можно сначала попробовать на выборке.")
                } else {
                    tableEstimates[source.id] = nil
                    infoMessage = String(localized: "Затронет файлов: \(plan.writeItems.count) — больше порога \(threshold). Проверьте план и подтвердите запуск.")
                }
            }
            return
        }
        await run(source, app: app, reason: .manual)
    }

    /// Runs the plan currently on screen, honouring unchecked files — reached
    /// either from the threshold gate or from "План" on a source below it.
    func runPlannedSync(_ source: DataSource, app: AppEnvironment) {
        guard !isBusy(source.id) else { return }
        let excluded = excludedPaths[source.id] ?? []
        pendingConfirmations.remove(source.id)
        beginOperation()
        busySourceIDs.insert(source.id)
        tasks[source.id] = Task { [weak self] in
            await self?.run(source, app: app, reason: .manual, excludedPaths: excluded)
            await MainActor.run {
                self?.excludedPaths[source.id] = []
                self?.endOperation()
                self?.busySourceIDs.remove(source.id)
                self?.tasks[source.id] = nil
            }
        }
    }

    func cancelPendingSync(_ sourceID: UUID) {
        pendingConfirmations.remove(sourceID)
        tableEstimates[sourceID] = nil
        plans[sourceID] = nil
        excludedPaths[sourceID] = nil
        // The banner announced a run that is no longer going to happen — left
        // behind it kept naming a file count and a threshold from a decision
        // the user had just cancelled.
        infoMessage = nil
    }

    /// One line for the queue panel and the source card — the queue is the only
    /// place progress lives now.
    static func progressLine(_ update: SyncProgress) -> String {
        var line = update.stage
        if update.totalFiles > 0 {
            line += ": \(update.processedFiles)/\(update.totalFiles) файлов, чанков записано \(update.chunksWritten)"
        }
        if let file = update.currentFile { line += " · \(file)" }
        return line
    }

    /// The one place a sync is actually started, whatever triggered it.
    ///
    /// Manual buttons and the automatic coordinator go through here, so an
    /// automatic run behaves exactly like a manual one — same validation, same
    /// progress, same report — and differs only in the reason it names.
    @discardableResult
    func run(
        _ source: DataSource,
        app: AppEnvironment,
        reason: SyncReason,
        excludedPaths: Set<String> = [],
        reextraction: SourceSyncService.ReextractionRequest? = nil,
        /// a trial run on the first rows of each sheet.
        tableRowLimit: Int? = nil
    ) async -> SyncSummary? {
        guard let chroma = app.client else {
            let message = "Нет подключения к ChromaDB. Подключитесь на экране «Подключение»."
            if reason.isAutomatic {
                app.log.record(.warning, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) пропущена: нет подключения к ChromaDB")
            } else {
                errorMessage = message
            }
            return nil
        }
        // the client would refuse every write anyway; saying so before the
        // run starts is the difference between an explanation and a pile of
        // identical errors halfway through a folder.
        if app.connection.isReadOnly {
            let message = String(localized: "Подключение открыто только для чтения — источники не синхронизируются. Снимите режим в профиле подключения.")
            if reason.isAutomatic {
                app.log.record(.warning, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) пропущена: подключение только для чтения")
            } else {
                errorMessage = message
            }
            return nil
        }
        guard let model = source.embeddingModel ?? app.settings.configuration.defaultEmbeddingModel else {
            if reason.isAutomatic {
                app.log.record(.warning, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) пропущена: модель эмбеддинга не выбрана")
            } else {
                errorMessage = SyncError.noEmbeddingModel.localizedDescription
            }
            return nil
        }

        // The coordinator calls this directly, so the claim has to exist here
        // too — otherwise a manual press during an automatic run would slip
        // through in exactly the same way.
        beginOperation()
        defer { endOperation() }
        busySourceIDs.insert(source.id)
        activeReason = reason
        errorMessage = nil
        infoMessage = nil
        lastSummary = nil
        // Только свой план: чужой на экране — про другой источник, и убирать
        // его этот запуск не вправе.
        plans[source.id] = nil
        pendingConfirmations.remove(source.id)
        if reason.isAutomatic {
            app.log.record(.info, "Источники", "Старт синхронизации «\(source.name)»: \(reason.title)")
        }

        var result: SyncSummary?
        do {
            let lmStudio = try app.makeLMStudioClient()
            // the queue decides when this runs. An automatic run yields to a
            // manual one, and both yield to the user's own search — between
            // batches, never inside one.
            let ticket = QueueTicket(
                title: String(localized: "Синхронизация «\(source.name)»"),
                priority: reason.isAutomatic ? .automatic : .manual,
                group: .lmStudio,
                connectionID: app.connectionID,
                resumable: ResumableRequest(
                    kind: .sync,
                    subject: source.id.uuidString,
                    title: String(localized: "Синхронизация «\(source.name)»")
                )
            )
            // Ссылки на службы берутся здесь, на главном потоке: замыкание
            // задачи исполняется вне его, и тянуться оттуда за свойствами
            // `AppEnvironment` — значит пересекать границу изоляции. Сами
            // службы к главному потоку не привязаны, поэтому достаточно
            // передать их внутрь.
            let webSync = app.webSync
            let gitSync = app.gitSync
            let summary = try await app.queue.run(ticket) { context in
                // Quitting or the panel's cancel button stops it properly,
                // whatever started it — the manual button or a timer.
                await app.queue.setCanceller(for: context.id) { [weak self] in
                    Task { @MainActor in self?.cancel(sourceID: source.id) }
                }
                // обход — задача той же очереди, отменяемая, с прогрессом
                // «обработано / в очереди». Внутри той же задачи, что и запись:
                // разрывать их значило бы отдать модель кому-то другому между
                // загрузкой страниц и их индексацией.
                let preparation = try await Self.prepareWebPages(
                    source: source, embeddingModel: model, app: app, context: context
                )
                defer { preparation?.discardCache() }
                // переименования переносятся **до** записи — иначе
                // синхронизация посчитает файл новым и заплатит за векторы,
                // которые уже посчитаны.
                let git = try await Self.prepareGitFiles(
                    source: source, embeddingModel: model, app: app,
                    context: context, chroma: chroma
                )
                let summary = try await app.syncService.sync(
                    source: source,
                    embeddingModel: model,
                    chroma: chroma,
                    embeddings: lmStudio,
                    binding: app.bindingService,
                    chat: lmStudio,
                    schemas: app.schemaStore.schemas,
                    contextLength: await app.bindingService.contextLength(of: model, lmStudio: lmStudio),
                    excludedPaths: excludedPaths,
                    reextraction: reextraction,
                    tableRowLimit: tableRowLimit,
                    reason: reason,
                    preparedPlan: preparation?.plan ?? git?.plan,
                    yield: { await context.yieldToHigherPriority() }
                ) { update in
                    Task { await context.report(progress: update.fraction, detail: Self.progressLine(update)) }
                }
                // Валидаторы запоминаются только после удачной записи: иначе
                // прерванный запуск научил бы приложение отвечать «не менялось»
                // о странице, которой в базе нет.
                if let preparation {
                    webSync.saveHistory(preparation.records, sourceID: source.id)
                }
                // Коммит и ветка запоминаются только после удачной записи:
                // иначе следующий запуск посчитал бы уже проиндексированным то,
                // что в базу не попало.
                if let git { gitSync.save(git.state, sourceID: source.id) }
                return summary
            }
            lastSummary = summary
            result = summary
            // значок в строке меню показывает ту же сводку, что экран.
            app.lastSyncSummary = "\(summary.notice.title). \(summary.notice.body)"
            // Прогон мог создать коллекцию и в любом случае изменил числа
            // документов. Экран коллекций держит свой список — без этой
            // отметки он показывал бы прежние числа, пока его не переоткроют
            //. Если прогон ничего не записал, беспокоить незачем.
            if !summary.wroteNothing { app.collectionsMayHaveChanged() }
            staleExtraction[source.id] = summary.staleExtraction.isEmpty ? nil : summary.staleExtraction
            var updated = source
            updated.lastSyncedAt = Date()
            app.settings.upsert(source: updated)
            if reason.isAutomatic {
                // An automatic run must never be invisible: it lands in the log
                // even when it changed nothing.
                app.log.record(
                    summary.wroteNothing ? .info : .success,
                    "Источники",
                    "Синхронизация «\(source.name)» (\(reason.title)): \(summary.line)"
                )
            }
            app.notify(summary.notice)
        } catch is CancellationError {
            app.log.record(.warning, "Источники", "Синхронизация «\(source.name)» отменена")
        } catch {
            if reason.isAutomatic {
                app.log.record(.error, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) не удалась: \(app.describe(error))")
            } else {
                errorMessage = app.describe(error)
            }
            app.notify(.failure(
                kind: .sync, subject: source.name, reason: app.describe(error)
            ))
            app.report(error, category: "Источники")
        }

        busySourceIDs.remove(source.id)
        // Причина остаётся, пока хоть что-то идёт: строка «идёт по расписанию»
        // относится к работе, а не к одному источнику из нескольких.
        if busySourceIDs.isEmpty { activeReason = nil }
        refreshManifests(app)
        return result
    }

    /// Обход веб-источника перед записью. Для папки возвращает `nil` — там
    /// план строится обходом папки, и ходить никуда не надо.
    private static func prepareWebPages(
        source: DataSource,
        embeddingModel: String,
        app: AppEnvironment,
        context: QueueContext
    ) async throws -> WebSyncService.Preparation? {
        guard source.isWeb else { return nil }
        let preparation = try await app.webSync.prepare(
            source: source,
            embeddingModel: embeddingModel,
            manifest: app.syncService.manifest(for: source.id),
            progress: { done, queued, current in
                Task {
                    await context.report(
                        progress: nil,
                        detail: queued > 0
                            ? String(localized: "Обход: обработано \(done.plainDigits), в очереди \(queued.plainDigits)")
                            : String(localized: "Обход: \(current)")
                    )
                }
            }
        )
        // Обход, остановленный пределом, — это не «сайт кончился»: человек
        // должен узнать об этом, и не только из сводки на экране.
        if let note = preparation.crawl.stop.note {
            app.log.record(.warning, "Веб", "Источник «\(source.name)»: \(note)")
        }
        return preparation
    }

    /// Разговор с git перед записью: план по ответам git и перенос
    /// переименованных файлов. Для не-git источника — `nil`, и синхронизация
    /// идёт обычным обходом папки.
    private static func prepareGitFiles(
        source: DataSource,
        embeddingModel: String,
        app: AppEnvironment,
        context: QueueContext,
        chroma: any SyncDatabase
    ) async throws -> GitSyncService.Preparation? {
        guard source.isGit else { return nil }
        var manifest = await app.syncService.manifest(for: source.id)
        guard let preparation = try await app.gitSync.prepare(
            source: source, embeddingModel: embeddingModel, manifest: manifest,
            progress: { done, total, current in
                Task {
                    await context.report(
                        progress: total > 0 ? Double(done) / Double(total) : nil,
                        detail: String(localized: "Репозиторий: \(done.plainDigits) из \(total.plainDigits) — \(current)")
                    )
                }
            }
        ) else { return nil }

        if let reason = preparation.degradedReason {
            // Деградация до обычной папки — это не тихий откат: человек должен
            // знать, почему индексация вдруг пошла дороже.
            await MainActor.run {
                app.log.record(.warning, "Git", "Источник «\(source.name)»: \(reason)")
            }
            return nil
        }

        guard !preparation.renames.isEmpty else { return preparation }
        let outcome = await GitRenames.apply(
            preparation.renames, sourceID: source.id, manifest: &manifest,
            chroma: chroma, log: { level, area, message in
                Task { @MainActor in app.log.record(level, area, message) }
            }
        )
        if outcome.moved > 0 {
            // Манифест сохраняется сразу: перенос уже произошёл в базе, и
            // прерванный на этом месте запуск не должен искать чанки по
            // старому имени.
            await app.syncService.save(manifest: manifest)
        }
        return preparation
    }

    // MARK: -: re-extraction

    /// «Переизвлечь и переэмбедить» — the operation an extractor version change
    /// offers instead of starting one.
    ///
    /// A backup first, always: this rewrites documents nobody complained about,
    /// and rule 5 of Приложение 5 does not make exceptions for improvements.
    func reextract(_ source: DataSource, app: AppEnvironment) {
        guard !isBusy(source.id) else { return }
        let paths = Set((staleExtraction[source.id] ?? []).map(\.relativePath))
        guard !paths.isEmpty else { return }

        errorMessage = nil
        infoMessage = nil
        // A backup runs before the first write and takes as long as it takes;
        // the panel is busy for all of it.
        beginOperation()
        busySourceIDs.insert(source.id)
        tasks[source.id] = Task { [weak self] in
            do {
                let backup = try await Self.makeBackup(for: source, app: app)
                let request = SourceSyncService.ReextractionRequest(paths: paths, backup: backup)
                let summary = await self?.run(source, app: app, reason: .manual, reextraction: request)
                await MainActor.run {
                    guard let summary else { return }
                    self?.infoMessage = "Переизвлечено файлов: \(summary.updated + summary.added). Бэкап: \(backup.describedAs)."
                }
            } catch {
                await MainActor.run { self?.errorMessage = app.describe(error) }
                app.report(error, category: "Источники")
            }
            await MainActor.run {
                self?.endOperation()
                self?.busySourceIDs.remove(source.id)
                self?.tasks[source.id] = nil
            }
        }
    }

    /// Local database: stop the server, copy the folder, start it again.
    /// External server: export the affected collections to JSON.
    ///
    /// Copying SQLite files under a running server produces a backup that
    /// restores into a corrupt database, which is why the server goes down —
    /// the same reasoning as re-embedding, and the same code path.
    private static func makeBackup(for source: DataSource, app: AppEnvironment) async throws -> BackupEvidence {
        let note = "перед переизвлечением источника \(source.name)"
        switch app.settings.configuration.mode {
        case .localDatabase:
            let path = app.localDatabaseURL
            app.log.record(.info, "Источники", "Останавливаем локальный сервер, чтобы скопировать папку базы")
            await app.disconnect()
            do {
                let evidence = try app.backupService.backupLocalDatabase(at: path, note: note)
                await app.connect()
                return evidence
            } catch {
                // The server comes back whether the copy worked or not.
                await app.connect()
                throw error
            }

        case .server:
            guard let chroma = app.client else { throw ChromaError.notConfigured }
            let manifest = await app.syncService.manifest(for: source.id)
            guard let name = manifest.collections.first,
                  let collection = try? await chroma.collection(named: name) else {
                throw ChromaError.notConfigured
            }
            return try await app.backupService.exportCollection(collection, from: chroma, note: note)
        }
    }

    /// «Синхронизировать все» — все источники подаются в очередь **сразу**.
    ///
    /// Раньше здесь стоял последовательный цикл с `await` на каждом источнике,
    /// с обоснованием «чтобы LM Studio не просили считать несколько папок
    /// разом». Обоснование лишнее: очередь и так пускает в группу `lmStudio`
    /// по одному (`canStart` проверяет `isRunning(group:)`), — а цикл делал
    /// то же самое **мимо неё**. Следствие: в очереди никогда не было больше
    /// одной заявки, панель «Задачи» стояла пустой, и человек видел, как
    /// источники синхронизируются друг за другом непонятно откуда.
    ///
    /// Теперь очередь и есть очередь: одна задача идёт, остальные видны
    /// ожидающими, и любую можно снять по отдельности.
    func syncAll(_ app: AppEnvironment) {
        guard !isSyncingAll else { return }
        // Уже идущие источники пропускаются: они и так в очереди, а второй
        // проход по тому же источнику — двойная работа над теми же файлами.
        let sources = app.settings.configuration.dataSources.filter { !isBusy($0.id) }
        guard !sources.isEmpty else { return }

        errorMessage = nil
        infoMessage = nil
        lastSummary = nil
        // One operation around the whole loop: between two folders `run` lowers
        // its own flag, and without this the panel would come back to life for
        // an instant in the middle of «Синхронизировать все».
        beginOperation()
        isSyncingAll = true

        tasks[Self.wholeList] = Task { [weak self] in
            var added = 0
            var updated = 0
            var done = 0

            guard let self else { return }
            // Задача каждого источника кладётся в `tasks` под его же
            // идентификатором — туда, где её ищет отмена.
            //
            // Кнопка «Отменить» у строки задачи зовёт `cancel(sourceID:)`,
            // а тот делает `tasks[sourceID]?.cancel()`. «Синхронизировать
            // все» туда не клала ничего никогда: раньше это не бросалось
            // в глаза, потому что очередь была не видна и отменять было
            // нечего.
            //
            // Отсюда и группа задач не годится: у её детей нет ручек,
            // которые можно положить в словарь. Отмена всего списка
            // доводится до детей вручную — у неструктурированных задач она
            // с родителя не наследуется.
            //
            // Подаются по порядку списка, но не дожидаясь друг друга:
            // `Task.yield()` между запусками даёт каждому дойти до очереди
            // раньше следующего.
            // Итоги собираются в общий счётчик: `tasks` хранит `Task<Void,
            // Never>`, и вернуть из ребёнка сводку напрямую нельзя.
            let totals = SyncAllTotals()
            var children: [(id: UUID, task: Task<Void, Never>)] = []
            for source in sources {
                if Task.isCancelled { break }
                let child = Task { @MainActor in
                    if let summary = await self.run(source, app: app, reason: .manual) {
                        totals.add(summary)
                    }
                }
                self.tasks[source.id] = child
                children.append((source.id, child))
                await Task.yield()
            }

            let started = children
            await withTaskCancellationHandler {
                for entry in started {
                    await entry.task.value
                    self.tasks[entry.id] = nil
                }
            } onCancel: {
                for entry in started { entry.task.cancel() }
            }
            added = totals.added
            updated = totals.updated
            done = totals.done

            await MainActor.run {
                self.infoMessage = "Синхронизировано источников: \(done) из \(sources.count). Добавлено \(added), обновлено \(updated)."
                self.endOperation()
                self.tasks[Self.wholeList] = nil
                self.isSyncingAll = false
            }
        }
    }

    /// «Остановить всё»: снимает и то, что идёт, и то, что ждёт очереди.
    func cancel() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        // A run started by a timer or a folder watcher belongs to the
        // coordinator; without this hook «Отменить» would only clear the
        // spinner and leave the work going.
        cancelAutomaticWork?()
        busySourceIDs.removeAll()
        isSyncingAll = false
        // A task cancelled before it ever ran never reaches its own release,
        // and a panel that stays busy forever is worse than the race this
        // counter exists to close.
        operationCount = 0
    }

    /// «Остановить» у карточки источника — только его работа.
    ///
    /// Остальные очередь доведёт до конца: человек, поставивший пять папок и
    /// ушедший, не должен терять четыре из-за одной передумавшей.
    func cancel(sourceID: UUID) {
        tasks[sourceID]?.cancel()
        tasks[sourceID] = nil
        busySourceIDs.remove(sourceID)
        if busySourceIDs.isEmpty && tasks.isEmpty {
            activeReason = nil
            operationCount = 0
        }
    }

    // MARK: - Pending removals

    func resolve(
        _ removal: PendingRemoval,
        decision: SourceSyncService.RemovalDecision,
        source: DataSource,
        app: AppEnvironment
    ) {
        Task { [weak self] in
            do {
                let deleted = try await app.syncService.resolve(
                    removal: removal,
                    decision: decision,
                    source: source,
                    chroma: app.client
                )
                await MainActor.run {
                    switch decision {
                    case .deleteChunks:
                        self?.infoMessage = "Файл \(removal.relativePath): удалено документов — \(deleted)."
                    case .keepInDatabase:
                        self?.infoMessage = "Файл \(removal.relativePath): документы оставлены в базе."
                    case .postpone:
                        break
                    }
                    self?.lastSummary = nil
                }
            } catch {
                await MainActor.run { self?.errorMessage = app.describe(error) }
                app.report(error, category: "Источники")
            }
            self?.refreshManifests(app)
        }
    }

    /// То же решение сразу о нескольких файлах.
    ///
    /// Список исчезнувших файлов бывает в десятки строк — на живой базе их
    /// было шестьдесят шесть, — и по каждой приходилось нажимать отдельно.
    /// Файлы разбираются **по одному**, а не одним запросом: удаление идёт
    /// коллекция за коллекцией, и оборвавшись на середине, оно оставляет
    /// разобранными те файлы, до которых дошло, а не непонятное состояние.
    func resolve(
        _ removals: [PendingRemoval],
        decision: SourceSyncService.RemovalDecision,
        source: DataSource,
        app: AppEnvironment
    ) {
        guard !removals.isEmpty else { return }
        Task { [weak self] in
            var deleted = 0
            var failed = 0
            for removal in removals {
                do {
                    deleted += try await app.syncService.resolve(
                        removal: removal, decision: decision, source: source, chroma: app.client
                    )
                } catch {
                    failed += 1
                    app.report(error, category: "Источники")
                    await MainActor.run { self?.errorMessage = app.describe(error) }
                }
            }
            let handled = removals.count - failed
            await MainActor.run {
                switch decision {
                case .deleteChunks:
                    self?.infoMessage = String(localized: "Файлов разобрано: \(handled.plainDigits), удалено документов — \(deleted.plainDigits).")
                case .keepInDatabase:
                    self?.infoMessage = String(localized: "Файлов разобрано: \(handled.plainDigits) — документы оставлены в базе.")
                case .postpone:
                    break
                }
                self?.lastSummary = nil
            }
            self?.refreshManifests(app)
        }
    }

    // MARK: - Schema hookup

    /// Coverage of the target collection's schema by the source, for the editor.
    func coverage(for source: DataSource, app: AppEnvironment) async -> SourceSchemaCoverage? {
        let name = CollectionNaming.sanitize(source.collectionName)
        guard let schema = app.schemaStore.schema(for: name), !schema.isEmpty else { return nil }
        return await app.syncService.coverage(source: source, schema: schema)
    }

    func draftSchemaFromSource(_ source: DataSource, app: AppEnvironment) {
        let name = CollectionNaming.sanitize(source.collectionName)
        let schema = MetadataSchema.drafted(collectionName: name, from: source)
        guard !schema.isEmpty else {
            infoMessage = "У источника нет своих полей метаданных — черновик схемы был бы пустым."
            return
        }
        app.schemaStore.save(schema)
        infoMessage = "Черновик схемы коллекции «\(name)» создан из полей источника: \(schema.fields.map(\.trimmedKey).joined(separator: ", ")). Отредактировать можно во вкладке «Коллекции»."
    }
}

extension SourcesViewModel {
    /// Model speed from what has been measured — the same order as everywhere
    /// else: real work first, the benchmark second, nothing invented.
    func secondsPerText(_ model: String, metrics: MetricsSnapshot, benchmarks: [ModelBenchmark]) -> Double? {
        if let measured = metrics.models.first(where: { $0.model == model }), measured.averageSeconds > 0 {
            return measured.averageSeconds
        }
        if let benchmark = benchmarks.first(where: { $0.model == model }), benchmark.secondsPerText > 0 {
            return benchmark.secondsPerText
        }
        return nil
    }

    func basis(_ model: String, metrics: MetricsSnapshot, benchmarks: [ModelBenchmark]) -> TableRunEstimate.Basis {
        if let measured = metrics.models.first(where: { $0.model == model }), measured.averageSeconds > 0 {
            return .measuredWork
        }
        if benchmarks.contains(where: { $0.model == model && $0.secondsPerText > 0 }) { return .benchmark }
        return .unknown
    }

    /// «попробовать на выборке» — the first rows only, so the template
    /// and the column roles can be judged before the whole sheet is paid for.
    func runSample(_ source: DataSource, app: AppEnvironment) {
        guard !isBusy(source.id) else { return }
        let limit = sampleRowCount
        pendingConfirmations.remove(source.id)
        tableEstimates[source.id] = nil
        beginOperation()
        busySourceIDs.insert(source.id)
        tasks[source.id] = Task { [weak self] in
            await self?.run(source, app: app, reason: .manual, tableRowLimit: limit)
            await MainActor.run {
                self?.infoMessage = String(localized: "Пробный прогон на первых \(limit) строках закончен. Посмотрите, что получилось в коллекции, и запустите полную синхронизацию, когда результат устроит.")
                self?.endOperation()
                self?.busySourceIDs.remove(source.id)
                self?.tasks[source.id] = nil
            }
        }
    }
}


/// Итоги «Синхронизировать все».
///
/// Ссылочным типом, потому что задачи источников возвращают `Void`: их ручки
/// кладутся в `tasks`, где их ищет отмена, а тот словарь хранит
/// `Task<Void, Never>`.
@MainActor
final class SyncAllTotals {
    private(set) var added = 0
    private(set) var updated = 0
    private(set) var done = 0

    func add(_ summary: SyncSummary) {
        added += summary.added
        updated += summary.updated
        done += 1
    }
}
