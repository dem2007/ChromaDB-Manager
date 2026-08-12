import Foundation
import SwiftUI
import AppKit
import ChromaCore

/// «Стенд оценки» — the screen that runs a set of queries against several
/// variants and keeps the answers.
@MainActor
final class EvaluationViewModel: ObservableObject {
    @Published var sets: [QuerySet] = []
    @Published var selectedSetID: UUID?
    /// What is being compared right now. Not persisted on its own: a plan
    /// belongs to the run it produced, and the run keeps it whole.
    @Published var variants: [EvaluationVariant] = []
    @Published var collections: [ChromaCollection] = []
    /// Модели LM Studio для выпадающего списка оценки: сначала
    /// помеченные «Чат / LLM», потом остальные — порядок живёт в ядре
    /// и там же проверяется тестом.
    @Published var chatModels: [LMStudioModel] = []
    @Published var runs: [EvaluationRunSummary] = []
    @Published var lastRun: EvaluationRun?
    /// Метрики последнего открытого прогона. Считаются по свежему
    /// набору, а не по снимку: разметка после прогона обязана менять числа
    /// без повторного прогона.
    @Published var metrics: [VariantMetrics] = []
    /// Эталон, по которому сейчас считаются метрики, — по идентификатору
    /// запроса. Держится рядом, чтобы каждая карточка результата знала свою
    /// оценку, не перебирая набор заново на каждую перерисовку.
    @Published private(set) var groundTruth: [UUID: EvaluationQuery] = [:]
    /// Готовые оценки «(запрос, документ) → градация» открытого прогона.
    ///
    /// Экран спрашивает оценку у каждой строки выдачи при каждой перерисовке,
    /// а вычисление её требует приведения текста результата — на живом прогоне
    /// это 209 мс на проход. Считается один раз вместе с метриками.
    @Published private(set) var grades: EvaluationMetrics.GradeIndex?
    /// Строки детализации и оговорка о длине — тоже посчитанные, а не
    /// вычисляемые в `body`.
    @Published private(set) var rows: [EvaluationReport.QueryRow] = []
    @Published private(set) var lengthCaveat: String?

    @Published var cost: EvaluationCost?
    @Published var isRunning = false
    @Published var progress: EvaluationRunner.Progress?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    /// The variant being put together in the sheet.
    @Published var draft: VariantDraft?

    // MARK: - Отчёт

    /// Прогон, с которым сравнивается текущий. `nil` — сравнения нет, и
    /// таблица «было/стало» не показывается вовсе: сравнение с пустотой это
    /// не сравнение.
    @Published var comparisonRunID: UUID?
    @Published private(set) var comparisonRun: EvaluationRun?
    @Published var showAllQueries = false
    /// Куда сохранён последний экспорт — чтобы сказать это, а не просто
    /// «готово».
    @Published var exportMessage: String?

    private var runTask: Task<Void, Never>?

    struct VariantDraft {
        var collectionName: String = ""
        var profileID: UUID?
        var nResults: Int = 10
        var name: String = ""
    }

    var selectedSet: QuerySet? {
        guard let selectedSetID else { return nil }
        return sets.first { $0.id == selectedSetID }
    }

    var canRun: Bool {
        !isRunning && !(selectedSet?.queries.isEmpty ?? true) && !variants.isEmpty
    }

    // MARK: - Загрузка

    func load(_ app: AppEnvironment) async {
        sets = app.querySets.all()
        if selectedSetID == nil || !sets.contains(where: { $0.id == selectedSetID }) {
            selectedSetID = sets.first?.id
        }
        runs = app.evaluationRuns.summaries()

        // Сначала база — она нужна экрану, чтобы можно было добавить вариант.
        if let client = app.client {
            do {
                collections = try await client.listCollections(withCounts: false)
            } catch {
                errorMessage = app.describe(error)
            }
        } else {
            collections = []
        }
        await updateCost(app)

        // Список моделей LM Studio — **отдельно и не блокируя**. Он нужен
        // только выпадающему списку необязательного режима D1.5, а запрос
        // к LM Studio встаёт в очередь за работающим эмбеддингом: пока шла
        // синхронизация, экран «Оценка» открывался с пустым списком
        // коллекций и выглядел зависшим.
        Task { [weak self] in
            guard let lmStudio = try? app.makeLMStudioClient(),
                  let loaded = try? await lmStudio.models()
            else { return }
            await MainActor.run {
                self?.chatModels = ModelPickerOrder.sorted(loaded, preferring: .chat)
            }
        }
    }

    // MARK: - Наборы запросов

    /// Набор, который сейчас создают или переименовывают.
    ///
    /// Отдельный черновик, а не правка на месте: набор — часы ручной разметки,
    /// и переименование, случившееся от одного нажатия клавиши, — не то,
    /// о чём просили (правило 1).
    struct SetDraft: Identifiable {
        /// `nil` — создаётся новый.
        var id: UUID?
        var name: String = ""
        var note: String = ""
        var isNew: Bool { id == nil }
    }

    @Published var setDraft: SetDraft?
    /// Набор, который спрашивают перед удалением. Удаление набора уносит
    /// с собой весь эталон, и молча этого делать нельзя.
    @Published var setPendingDeletion: QuerySet?

    func newSet() {
        setDraft = SetDraft(name: String(localized: "Новый набор"))
    }

    func renameSet() {
        guard let set = selectedSet else { return }
        setDraft = SetDraft(id: set.id, name: set.name, note: set.note)
    }

    func saveSet(_ app: AppEnvironment) {
        guard let draft = setDraft else { return }
        let existing = draft.id.flatMap { app.querySets.set(id: $0) }
        var set = existing ?? QuerySet(name: draft.name)
        set.name = draft.name
        set.note = draft.note
        let saved = app.querySets.save(set)
        setDraft = nil
        sets = app.querySets.all()
        selectedSetID = saved.id
        statusMessage = existing == nil
            ? String(localized: "Набор «\(saved.name)» создан.")
            : String(localized: "Набор переименован в «\(saved.name)».")
        Task { await updateCost(app) }
    }

    func requestSetDeletion() {
        setPendingDeletion = selectedSet
    }

    func deleteSet(_ app: AppEnvironment) {
        guard let set = setPendingDeletion else { return }
        setPendingDeletion = nil
        app.querySets.remove(id: set.id)
        sets = app.querySets.all()
        selectedSetID = sets.first?.id
        statusMessage = String(localized: "Набор «\(set.name)» удалён вместе с эталоном. Сохранённые прогоны остались — они хранят свои запросы целиком.")
        Task { await updateCost(app) }
    }

    func exportSet(_ app: AppEnvironment) {
        guard let set = selectedSet else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт набора запросов")
        panel.nameFieldStringValue = FileNaming.suggested(set.name, extension: "json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.querySets.exportData(set).write(to: url, options: .atomic)
            exportMessage = String(localized: "Набор сохранён: \(url.path)")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    /// Импорт **добавляет** набор с новым идентификатором, а не заменяет
    /// одноимённый: файл мог приехать с той же машины, и молча затирать
    /// разметку, которую никто не просил трогать, нельзя.
    func importSet(_ app: AppEnvironment) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт набора запросов")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = app.querySets.save(try app.querySets.importing(try Data(contentsOf: url)))
            sets = app.querySets.all()
            selectedSetID = imported.id
            statusMessage = String(localized: "Загружен набор «\(imported.name)»: \(imported.line). Существующие наборы не затронуты.")
            Task { await updateCost(app) }
        } catch {
            errorMessage = app.describe(error)
        }
    }

    // MARK: - Запросы набора

    /// Запрос, который сейчас пишут руками.
    ///
    /// ТЗ называет наполнение из истории основным способом — и это правда,
    /// двадцать запросов руками никто не пишет. Но «основной» не значит
    /// «единственный»: без этого нельзя ни исправить опечатку, ни добавить
    /// запрос, которого ещё не искали, ни разметить теги.
    struct QueryDraft: Identifiable {
        var id: UUID?
        var text: String = ""
        var tags: String = ""
        var comment: String = ""
        var filter: DocumentFilter?
        var isNew: Bool { id == nil }
    }

    @Published var queryDraft: QueryDraft?

    func newQuery() {
        guard selectedSet != nil else { return }
        queryDraft = QueryDraft()
    }

    func editQuery(_ query: EvaluationQuery) {
        queryDraft = QueryDraft(
            id: query.id,
            text: query.text,
            tags: query.tags.joined(separator: ", "),
            comment: query.comment,
            filter: query.filter
        )
    }

    /// Поля, которые предлагает редактор фильтра.
    ///
    /// Собираются по схемам **всех** коллекций сразу, а не одной: набор
    /// принадлежит задаче, а не коллекции, и один и тот же набор
    /// гоняют по вариантам с разными схемами. Это подсказка, а не
    /// ограничение — своё имя поля можно вписать руками.
    func filterFields(_ app: AppEnvironment) -> [String] {
        let fromSchemas = collections
            .compactMap { app.schemaStore.schema(for: $0.name) }
            .flatMap { $0.fields.map(\.key) }
        return Set(fromSchemas).sorted()
    }

    func saveQuery(_ app: AppEnvironment) {
        // Набор перечитывается из хранилища, а не берётся из `sets`.
        // `save` пишет набор целиком, и запись устаревшей копии затёрла бы
        // разметку, сделанную после того, как копия была снята. Сегодня
        // `mark` обновляет `sets` сам, но «работает, потому что соседний
        // метод не забыл» — не то свойство, на которое кладут эталон.
        guard let draft = queryDraft,
              let selectedSetID,
              var set = app.querySets.set(id: selectedSetID)
        else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = String(localized: "У запроса должен быть текст.")
            return
        }
        let tags = draft.tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let id = draft.id, let index = set.queries.firstIndex(where: { $0.id == id }) {
            // Правка не трогает эталон: фрагменты — отдельная работа, и
            // исправленная опечатка в тексте её не отменяет.
            set.queries[index].text = text
            set.queries[index].tags = tags
            set.queries[index].comment = draft.comment
            set.queries[index].filter = draft.filter
        } else {
            set.queries.append(EvaluationQuery(
                text: text, filter: draft.filter, tags: tags, comment: draft.comment
            ))
        }
        app.querySets.save(set)
        queryDraft = nil
        sets = app.querySets.all()
        Task { await updateCost(app) }
    }

    /// Запрос, который спрашивают перед удалением: вместе с ним уходит и его
    /// эталон.
    @Published var queryPendingDeletion: EvaluationQuery?

    func removeQuery(_ app: AppEnvironment) {
        // Тоже из хранилища, а не из кэша — по той же причине, что в `saveQuery`.
        guard let query = queryPendingDeletion,
              let selectedSetID,
              var set = app.querySets.set(id: selectedSetID)
        else { return }
        queryPendingDeletion = nil
        set.queries.removeAll { $0.id == query.id }
        app.querySets.save(set)
        sets = app.querySets.all()
        statusMessage = query.hasGroundTruth
            ? String(localized: "Запрос удалён вместе с эталоном — размеченных фрагментов было \(query.fragments.count + query.documents.count).")
            : String(localized: "Запрос удалён.")
        Task { await updateCost(app) }
    }

    // MARK: - Варианты

    func beginVariant(_ app: AppEnvironment) {
        var draft = VariantDraft()
        draft.collectionName = collections.first?.name ?? ""
        draft.profileID = nil
        draft.name = draft.collectionName
        self.draft = draft
    }

    func profiles(for collectionName: String, app: AppEnvironment) -> [SearchProfile] {
        app.searchProfiles.profiles(for: collectionName)
    }

    /// Adds the drafted variant, resolving what the collection itself dictates:
    /// the model it is bound to and the metric its vectors were written with.
    func addVariant(_ app: AppEnvironment) async {
        guard let draft, let collection = collections.first(where: { $0.name == draft.collectionName }) else { return }
        do {
            let model = try await app.bindingService.requiredModel(for: collection)
            let profile = draft.profileID.flatMap { app.searchProfiles.profile(id: $0) }
                ?? app.searchProfiles.effectiveProfile(for: collection.name)
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            variants.append(EvaluationVariant(
                name: name.isEmpty ? "\(collection.name) · \(profile.name)" : name,
                collectionID: collection.id,
                collectionName: collection.name,
                model: model,
                metric: collection.space,
                nResults: draft.nResults,
                profile: profile,
                note: String(localized: "модель \(model)")
            ))
            self.draft = nil
            await updateCost(app)
        } catch {
            errorMessage = app.describe(error)
        }
    }

    func removeVariant(_ variant: EvaluationVariant, app: AppEnvironment) {
        variants.removeAll { $0.id == variant.id }
        Task { await updateCost(app) }
    }

    func updateCost(_ app: AppEnvironment) async {
        guard let set = selectedSet, !variants.isEmpty else {
            cost = nil
            return
        }
        let metrics = await app.metrics.current()
        let benchmarks = await app.benchmarks.all()
        cost = EvaluationCost.estimate(
            queries: set.queries, variants: variants, metrics: metrics, benchmarks: benchmarks
        )
    }

    // MARK: - Прогон

    func run(_ app: AppEnvironment) {
        guard let set = selectedSet, let client = app.client, !variants.isEmpty else { return }
        let lmStudio: LMStudioClient
        do {
            lmStudio = try app.makeLMStudioClient()
        } catch {
            errorMessage = app.describe(error)
            return
        }
        isRunning = true
        errorMessage = nil
        statusMessage = nil
        progress = nil

        let variants = self.variants
        let plannedCells = set.queries.count * variants.count
        let logHandler = app.logHandler

        runTask = Task { [weak self] in
            let runner = EvaluationRunner(
                embed: { [queue = app.queue, id = app.connectionID] text, model in
                    // Through the same queue as every other use of the local
                    // model: a run started while a folder syncs must
                    // wait its turn rather than race it. Not `.interactive`:
                    // a run is minutes of work, and it must not push aside the
                    // search somebody is waiting for on screen.
                    try await queue.run(QueueTicket(
                        title: String(localized: "Оценка: вектор запроса"),
                        priority: .manual,
                        group: .lmStudio,
                        connectionID: id
                    )) { _ in
                        try await lmStudio.embed(text: text, model: model)
                    }
                },
                search: { [shapes = app.collectionShapes, queue = app.queue, id = app.connectionID, binding = app.bindingService] variant, query, vector in
                    // Тот же бюджет промпта, что и в обычном поиске:
                    // вариант, у которого переранжирование молча обрезалось бы
                    // по контексту, давал бы на стенде метрику не той настройки,
                    // которую он описывает, — а стенд ради сравнения настроек
                    // и существует.
                    let rerankContext: Int? = variant.profile.rerankEnabled
                        && !variant.profile.rerankModel.isEmpty
                        ? await binding.loadedContextLength(
                            of: variant.profile.rerankModel, lmStudio: lmStudio
                        )
                        : nil
                    // The one search path in the app. The vector is
                    // already computed — that is the whole point — so the
                    // pipeline's embedder just hands it over.
                    let pipeline = RetrievalPipeline(
                        database: client,
                        shapes: shapes,
                        embed: { _ in vector ?? [] },
                        complete: { prompt, chatModel, schema in
                            try await queue.run(QueueTicket(
                                title: String(localized: "Оценка: переранжирование"),
                                priority: .manual,
                                group: .lmStudio,
                                connectionID: id
                            )) { _ in
                                try await lmStudio.complete(prompt: prompt, model: chatModel, schema: schema)
                            }
                        },
                        completePlain: { prompt, model in
                            // Режим переранжировщика обязан работать
                            // и на стенде: иначе вариант с ним не сравнить
                            // ни с чем.
                            try await queue.run(QueueTicket(
                                title: String(localized: "Оценка: переранжирование"),
                                priority: .manual,
                                group: .lmStudio,
                                connectionID: id
                            )) { _ in
                                try await lmStudio.rawCompletion(prompt: prompt, model: model)
                            }
                        },
                        rerankContextTokens: rerankContext,
                        log: logHandler
                    )
                    return try await pipeline.run(
                        RetrievalRequest(
                            text: query.text,
                            collectionID: variant.collectionID,
                            collectionName: variant.collectionName,
                            nResults: variant.nResults,
                            filter: query.filter ?? variant.filter,
                            metric: variant.metric
                        ),
                        profile: variant.profile
                    )
                },
                log: logHandler
            )

            let run = await runner.run(
                set: set,
                variants: variants,
                appVersion: SettingsTransferViewModel.appVersion,
                progress: { step in
                    Task { @MainActor in self?.progress = step }
                }
            )
            let calls = await runner.embeddingCallCount

            await MainActor.run {
                guard let self else { return }
                app.evaluationRuns.save(run)
                self.lastRun = run
                self.refreshMetrics(app)
                self.loadJudgements(app)
                self.runs = app.evaluationRuns.summaries()
                self.progress = nil
                self.isRunning = false
                self.statusMessage = run.isComplete
                    ? String(localized: "Прогон завершён: \(EvaluationCost.searches(plannedCells)), вызовов эмбеддинга \(calls). Результаты сохранены.")
                    : run.note
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        statusMessage = String(localized: "Отмена: уже полученные результаты сохранятся.")
    }

    func openRun(_ summary: EvaluationRunSummary, app: AppEnvironment) {
        lastRun = app.evaluationRuns.run(id: summary.id)
        refreshMetrics(app)
        loadJudgements(app)
    }

    /// Пересчёт метрик по тому, что размечено сейчас.
    /// Всё, что зависит от прогона и эталона, считается **здесь** — один раз
    /// на изменение, а не в `body` на каждую перерисовку.
    func refreshMetrics(_ app: AppEnvironment) {
        guard let run = lastRun else {
            metrics = []
            groundTruth = [:]
            grades = nil
            rows = []
            lengthCaveat = nil
            return
        }
        let set = app.querySets.set(id: run.querySetID)
        let truth = EvaluationMetrics.groundTruth(for: run, set: set)
        let index = EvaluationMetrics.GradeIndex(run: run, truth: truth)
        groundTruth = truth
        grades = index
        metrics = EvaluationMetrics.compute(run: run, set: set, ks: ks(app), grades: index)
        rows = EvaluationReport.queryRows(run: run, set: set, grades: index)
        lengthCaveat = EvaluationReport.lengthCaveat(run)
        refreshComparison(app)
    }

    // MARK: - Отчёт и экспорт

    /// `k` из настроек, а не зашитые 5 и 10: D1.3 требует настраиваемое
    /// значение. Приведение к пригодному виду живёт в ядре и под тестом.
    func ks(_ app: AppEnvironment) -> [Int] {
        EvaluationMetrics.sanitisedKs(app.settings.configuration.evaluationKs)
    }

    func table(_ app: AppEnvironment) -> EvaluationReport.Table? {
        metrics.isEmpty ? nil : EvaluationReport.table(metrics, ks: ks(app))
    }



    /// Сравнение с выбранным прогоном. `nil`, пока прогон не выбран, —
    /// и тогда блок «было/стало» не рисуется вовсе.
    ///
    /// Считается при выборе прогона, а не в `body`: `compare` пересчитывает
    /// метрики **обоих** прогонов, то есть вдвое дороже обычного пересчёта
    ///.
    @Published private(set) var comparison: EvaluationReport.RunComparison?

    private func refreshComparison(_ app: AppEnvironment) {
        guard let after = lastRun, let before = comparisonRun else {
            comparison = nil
            return
        }
        comparison = EvaluationReport.compare(
            before: before, after: after,
            beforeSet: app.querySets.set(id: before.querySetID),
            afterSet: app.querySets.set(id: after.querySetID),
            ks: ks(app)
        )
    }

    func selectComparison(_ id: UUID?, app: AppEnvironment) {
        comparisonRunID = id
        guard let id else {
            comparisonRun = nil
            refreshComparison(app)
            return
        }
        comparisonRun = app.evaluationRuns.run(id: id)
        if comparisonRun == nil {
            comparisonRunID = nil
            errorMessage = String(localized: "Прогон для сравнения не удалось прочитать.")
        }
        refreshComparison(app)
    }

    /// Экспорт отчёта. Формат выбирается расширением файла в диалоге, а не
    /// отдельным переключателем: два пункта меню — это и есть выбор.
    func export(markdown: Bool, app: AppEnvironment) {
        guard let run = lastRun else { return }
        let set = app.querySets.set(id: run.querySetID)
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт отчёта")
        panel.nameFieldStringValue = FileNaming.suggested(
            run.name, suffix: "-report", extension: markdown ? "md" : "json"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data = markdown
                ? Data(EvaluationExport.markdown(run: run, set: set, ks: ks(app)).utf8)
                : try EvaluationExport.json(run: run, set: set, ks: ks(app))
            try data.write(to: url, options: .atomic)
            // Куда именно сохранено — а не просто «готово»: файл нужно найти.
            exportMessage = String(localized: "Отчёт сохранён: \(url.path)")
            app.log.record(.info, "Оценка", "Отчёт прогона «\(run.name)» выгружен в \(url.path)")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    // MARK: - Оценка чат-моделью

    /// Оценки модели по открытому прогону. Пусто — режим не запускался.
    @Published private(set) var judgements: JudgementSet?
    @Published var isJudging = false
    @Published var judgeProgress: ModelJudge.Progress?
    @Published var judgeCost: JudgementCost?
    /// Подтверждение перед стартом: ТЗ требует предупредить и о стоимости,
    /// и о том, что оценка модели не истина.
    @Published var pendingJudgement: JudgementCost?
    private var judgeTask: Task<Void, Never>?

    /// Оценка модели для одного результата — `nil`, если не оценивался.
    func judgement(queryID: UUID, variantID: UUID, hit: EvaluationHit) -> ModelJudgement? {
        judgements?.judgement(query: queryID, variant: variantID, document: hit.id)
    }

    func loadJudgements(_ app: AppEnvironment) {
        guard let run = lastRun else {
            judgements = nil
            judgeCost = nil
            return
        }
        judgements = app.modelJudgements.set(for: run.id)
        Task { await updateJudgeCost(app) }
    }

    func updateJudgeCost(_ app: AppEnvironment) async {
        guard let run = lastRun,
              app.settings.configuration.modelJudgeEnabled,
              let model = app.settings.configuration.modelJudgeModel
        else {
            judgeCost = nil
            return
        }
        let metrics = await app.metrics.current()
        judgeCost = JudgementCost.estimate(
            run: run,
            existing: judgements,
            promptFingerprint: app.settings.configuration.modelJudgePrompt.fingerprint,
            secondsPerCall: metrics.judgeSecondsPerCall(model: model)
        )
    }

    /// Спрашивает до того, как занять модель. Отдельным шагом, а не
    /// подтверждением в кнопке: числа в вопросе — это и есть предупреждение.
    func requestJudgement(_ app: AppEnvironment) async {
        await updateJudgeCost(app)
        guard let cost = judgeCost, cost.calls > 0 else { return }
        pendingJudgement = cost
    }

    func cancelPendingJudgement() { pendingJudgement = nil }

    func cancelJudgement() { judgeTask?.cancel() }

    func startJudgement(_ app: AppEnvironment) {
        guard pendingJudgement != nil,
              let run = lastRun,
              let model = app.settings.configuration.modelJudgeModel
        else { return }
        pendingJudgement = nil
        let prompt = app.settings.configuration.modelJudgePrompt
        if let problem = prompt.problem {
            errorMessage = problem
            return
        }

        judgeTask = Task { [weak self] in
            guard let self else { return }
            self.isJudging = true
            self.errorMessage = nil
            defer {
                self.isJudging = false
                self.judgeProgress = nil
            }
            do {
                let client = try app.makeLMStudioClient()
                let judge = ModelJudge(
                    grade: { prompt, model, schema in
                        try await client.complete(
                            prompt: prompt, model: model,
                            settings: ChatGenerationSettings(), schema: schema
                        )
                    },
                    log: app.logHandler
                )
                let started = Date()
                // **Через очередь, а не мимо неё.** Оценка занимает локальную
                // модель на минуты, а очередь существует ровно затем,
                // чтобы такое было видно на экране «Задачи» и не шло
                // одновременно с синхронизацией. Первая редакция звала модель
                // напрямую: приложение было занято, а показать это было
                // нечем.
                //
                // Один билет на весь прогон, а не на вызов: сорок строк
                // в очереди — это не сведения, а шум, и прерваться между
                // вызовами всё равно можно только отменой.
                let ticket = QueueTicket(
                    title: String(localized: "Оценка чат-моделью «\(model)»"),
                    priority: .manual,
                    group: .lmStudio,
                    connectionID: app.connectionID
                    // Не возобновляемая: у прогона оценки нет «половины» —
                    // уже полученные оценки сохранены, а остаток считается
                    // обычным запуском, который сам пропустит сделанное.
                )
                let produced = try await app.queue.run(ticket) { context in
                    await app.queue.setCanceller(for: context.id) { [weak self] in
                        Task { @MainActor in self?.cancelJudgement() }
                    }
                    return await judge.run(
                        run: run, model: model, prompt: prompt,
                        existing: app.modelJudgements.set(for: run.id)
                    ) { progress in
                        Task { @MainActor in self.judgeProgress = progress }
                        Task { await context.report(
                            progress: progress.total > 0
                                ? Double(progress.done) / Double(progress.total)
                                : nil,
                            detail: progress.line
                        ) }
                    }
                }
                app.modelJudgements.save(produced)
                // Измеренная скорость — то, из чего сложится оценка времени
                // следующего прогона, и единственный её источник (12.7).
                // Записывается **до** проверки экрана: измерение сделано,
                // и терять его оттого, что человек тем временем открыл
                // другой прогон, незачем.
                let calls = await judge.measuredCalls
                if calls > 0 {
                    await app.metrics.recordJudgement(
                        model: model, calls: calls, duration: Date().timeIntervalSince(started)
                    )
                }
                // На экран — только если это всё ещё тот прогон. Оценка идёт
                // минутами, и за это время можно открыть другой: записать в
                // файл нужно всегда, показать чужие оценки — нельзя.
                // (Тот же класс, что «устаревшая копия поверх свежего файла».)
                guard self.lastRun?.id == run.id else { return }
                self.judgements = produced
                self.statusMessage = produced.line
                await self.updateJudgeCost(app)
            } catch is CancellationError {
                // Отмена — не ошибка: полученные оценки уже сохранены самим
                // прогоном, и красная плашка про них соврала бы.
                self.judgements = app.modelJudgements.set(for: run.id)
                await self.updateJudgeCost(app)
                app.log.record(.info, "Оценка", "Оценка чат-моделью отменена — полученные оценки сохранены")
            } catch {
                self.errorMessage = app.describe(error)
                app.report(error, category: "Оценка")
            }
        }
    }

    /// Превращает оценку модели в разметку — по нажатию человека и никак иначе.
    ///
    /// Здесь и проходит граница, которую ТЗ требует держать: модель предлагает,
    /// эталон пишет человек. Кнопка ставит ровно ту же отметку, что и три
    /// кнопки рядом, — просто не заставляет перечитывать текст.
    func acceptJudgement(_ judgement: ModelJudgement, hit: EvaluationHit, app: AppEnvironment) {
        mark(
            queryID: judgement.queryID, variantID: judgement.variantID,
            hit: hit, grade: judgement.grade, app: app
        )
    }

    // MARK: - Разметка

    /// Оценка, уже стоящая у этого результата, — `nil` значит «не размечено».
    func grade(queryID: UUID, variantID: UUID, hit: EvaluationHit) -> RelevanceGrade? {
        grades?.grade(query: queryID, variant: variantID, document: hit.id)
    }

    /// Ставит оценку результату — или снимает её, если она уже стоит.
    ///
    /// Отметка уходит **в эталон набора**, а не в прогон: прогон — это то, что
    /// поиск ответил, а эталон — то, каким ответ должен был быть. Поэтому
    /// разметка одного прогона работает и для следующего, и для варианта,
    /// нарезанного иначе.
    func mark(queryID: UUID, variantID: UUID, hit: EvaluationHit, grade: RelevanceGrade, app: AppEnvironment) {
        guard let run = lastRun else { return }
        guard app.querySets.set(id: run.querySetID) != nil else {
            errorMessage = String(localized: "Набор «\(run.querySetName)» удалён — размечать некуда. Прогон остаётся, но его выдачу больше не с чем сравнивать.")
            return
        }

        let existing = self.grade(queryID: queryID, variantID: variantID, hit: hit)
        let removed = existing == grade
        let done = removed
            ? app.querySets.unmark(queryID: queryID, in: run.querySetID, documentID: hit.id, text: hit.text)
            : app.querySets.mark(
                queryID: queryID, in: run.querySetID, documentID: hit.id, text: hit.text,
                grade: grade, note: String(localized: "из прогона «\(run.name)»")
            )
        guard done else {
            errorMessage = String(localized: "Этого запроса в наборе больше нет — отметку сохранять некуда.")
            return
        }

        sets = app.querySets.all()
        // Немедленно и без повторного прогона: выдача уже сохранена.
        refreshMetrics(app)
        statusMessage = removed
            ? String(localized: "Отметка снята.")
            : String(localized: "Отмечено «\(grade.title)» — сохранено в эталон набора «\(run.querySetName)» как фрагмент найденного текста.")
    }

    func removeRun(_ summary: EvaluationRunSummary, app: AppEnvironment) {
        app.evaluationRuns.remove(id: summary.id)
        // Мнение модели о прогоне, которого больше нет, — мусор, который
        // потом невозможно опознать.
        app.modelJudgements.remove(runID: summary.id)
        if lastRun?.id == summary.id {
            lastRun = nil
            metrics = []
            judgements = nil
            judgeCost = nil
        }
        runs = app.evaluationRuns.summaries()
    }
}
