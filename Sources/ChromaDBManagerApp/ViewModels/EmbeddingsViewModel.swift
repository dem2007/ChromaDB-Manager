import AppKit
import Foundation
import ChromaCore

/// LM Studio half of the «Эмбеддинги» tab: connection, model list, model types
/// and the default embedding model. Sources live in `SourcesViewModel`.
@MainActor
final class EmbeddingsViewModel: ObservableObject {
    @Published var models: [LMStudioModel] = []
    @Published var isChecking = false
    @Published var connectionMessage: String?
    @Published var errorMessage: String?
    /// Итог пробы после ручной смены вида модели.
    @Published var overrideWarning: String?
    /// what the cache holds and how often it saved a call to the model.
    @Published var cacheStatistics: EmbeddingCache.Statistics?
    @Published var isClearingCache = false

    /// measured model speeds, and the confirmation shown before a run.
    @Published private(set) var benchmarks: [ModelBenchmark] = []
    /// Почему замеры не сохраняются, если это так.
    @Published private(set) var benchmarksProblem: String?
    @Published private(set) var benchmarkingModel: String?
    private var benchmarkTask: Task<Void, Never>?

    /// Что человек подтверждает, прежде чем приложение займёт модель.
    ///
    /// Одним свойством, а не двумя: `.alert` на виде может быть **только
    /// один**, второй SwiftUI молча выбрасывает. Так и вышло — кнопка
    /// «Загрузить с N» ставила своё подтверждение, а показывался чужой alert,
    /// то есть никакой: состояние менялось, на экране не менялось ничего
    ///.
    enum PendingModelAction: Identifiable {
        /// замер занимает модель целиком и надолго.
        case benchmark(model: String, estimatedSeconds: Double?)
        /// перезагрузка модели с бо́льшим контекстом.
        case load(model: String, from: Int, to: Int)

        var model: String {
            switch self {
            case .benchmark(let model, _): return model
            case .load(let model, _, _): return model
            }
        }

        var id: String {
            switch self {
            case .benchmark: return "benchmark\u{0}\(model)"
            case .load: return "load\u{0}\(model)"
            }
        }
    }

    @Published var pendingAction: PendingModelAction?

    var embeddingModels: [LMStudioModel] {
        models.filter { $0.kind == .embedding }
    }

    /// Модели для выпадающих списков, где нужна порождающая модель
    /// (LLM-чанкинг, перечанковка, стенд): сначала помеченные «Чат / LLM»,
    /// потом остальные.
    ///
    /// **Почему список не фильтруется, а сортируется.** Раньше он показывал
    /// только `.chat`, и модель, тип которой определён неверно, из него просто
    /// исчезала — вместе со всякой возможностью её выбрать. Порядок решает ту
    /// же задачу («нужное сверху»), не отнимая доступа к остальному.
    var chatModels: [LMStudioModel] {
        ordered(preferring: .chat)
    }

    /// То же для стадии переранжирования: сначала помеченные «Реранкинг».
    var rerankModels: [LMStudioModel] {
        ordered(preferring: .reranking)
    }

    /// Идентификаторы моделей, помеченных как переранжировщики, — чтобы форма
    /// профиля могла предупредить по типу, а не по имени файла.
    var rerankingTypedIDs: Set<String> {
        Set(models.filter { $0.kind == .reranking }.map(\.id))
    }

    /// Правило порядка живёт в ядре — там оно проверяется тестом.
    private func ordered(preferring kind: LMStudioModelKind) -> [LMStudioModel] {
        ModelPickerOrder.sorted(models, preferring: kind)
    }

    // MARK: - LM Studio

    /// Loads the model list and, for models LM Studio does not type itself,
    /// probes `/v1/embeddings` to find out what they are.
    func checkConnection(_ app: AppEnvironment, probeUnknownModels: Bool = true) async {
        isChecking = true
        errorMessage = nil
        connectionMessage = nil
        defer { isChecking = false }

        do {
            let client = try app.makeLMStudioClient()
            var loaded = try await client.models()

            let overrides = app.settings.configuration.modelKindOverrides
            for index in loaded.indices {
                if let override = overrides[loaded[index].id],
                   let kind = LMStudioModelKind(rawValue: override) {
                    loaded[index].kind = kind
                    loaded[index].kindIsInferred = true
                }
            }

            if probeUnknownModels {
                for index in loaded.indices where loaded[index].kind == .unknown {
                    let kind = await client.detectKind(of: loaded[index].id)
                    loaded[index].kind = kind
                    loaded[index].kindIsInferred = true
                    app.log.record(.info, "LM Studio", "Тип модели \(loaded[index].id) определён пробным запросом: \(kind.title)")
                }
            }

            // В таблице порядок другой, чем в выпадающих списках: здесь это
            // перечень установленного, а не выбор под задачу.
            models = ModelPickerOrder.tableSorted(loaded)
            connectionMessage = "Подключено к \(app.settings.configuration.lmStudioBaseURL). Моделей: \(models.count), из них эмбеддинговых: \(embeddingModels.count)."

            if app.settings.configuration.defaultEmbeddingModel == nil,
               let first = embeddingModels.first {
                app.settings.configuration.defaultEmbeddingModel = first.id
            }
        } catch {
            models = []
            errorMessage = app.describe(error)
            app.report(error, category: "LM Studio")
        }
    }

    // MARK: - Список моделей сам по себе

    /// Когда список последний раз удалось получить. Показывается на экране:
    /// «пусто» и «не спрашивали» — разные вещи.
    @Published private(set) var modelsRefreshedAt: Date?
    private var autoRefreshTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    /// Пауза между тихими опросами. Растёт при неудачах, чтобы выключенная
    /// LM Studio не опрашивалась ежеминутно весь день.
    private var quietInterval: Duration = .seconds(60)

    /// Тихое обновление списка: один GET и ничего больше.
    ///
    /// Отличий от «Проверить соединение» три, и все важны для фона:
    /// * типы неизвестных моделей **не** выясняются пробным запросом — проба
    ///   загружает модель в память, и делать это по таймеру нельзя;
    /// * неудача не сбрасывает список и не пишется в лог: LM Studio может быть
    ///   просто не запущена, и говорить об этом раз в минуту — не сообщение,
    ///   а шум;
    /// * ранее определённые типы переносятся на новый список — иначе каждое
    ///   обновление стирало бы работу проб.
    func refreshModelsQuietly(_ app: AppEnvironment) async {
        guard let client = try? app.makeLMStudioClient() else { return }
        guard var loaded = try? await client.models() else {
            quietInterval = min(quietInterval * 2, .seconds(600))
            return
        }
        quietInterval = .seconds(60)

        let overrides = app.settings.configuration.modelKindOverrides
        let remembered = Dictionary(models.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        for index in loaded.indices {
            if let override = overrides[loaded[index].id],
               let kind = LMStudioModelKind(rawValue: override) {
                loaded[index].kind = kind
                loaded[index].kindIsInferred = true
            } else if loaded[index].kind == .unknown,
                      let previous = remembered[loaded[index].id], previous != .unknown {
                loaded[index].kind = previous
                loaded[index].kindIsInferred = true
            }
        }

        let sorted = ModelPickerOrder.tableSorted(loaded)
        modelsRefreshedAt = Date()
        // Присваивание @Published перерисовывает всех, кто на него подписан,
        // а список моделей читают четыре экрана и пять листов. Раз в минуту
        // он почти всегда тот же самый.
        guard sorted != models else { return }
        models = sorted
        if app.settings.configuration.defaultEmbeddingModel == nil,
           let first = embeddingModels.first {
            app.settings.configuration.defaultEmbeddingModel = first.id
        }
    }

    /// Держит список свежим, пока приложение работает.
    ///
    /// Опрос идёт **только когда приложение активно**: список нужен человеку,
    /// который смотрит на экран, а не свёрнутому окну. Возврат в приложение
    /// обновляет список сразу — так модель, загруженная в LM Studio минуту
    /// назад, появляется к тому моменту, когда за ней пришли.
    func startAutomaticRefresh(_ app: AppEnvironment) {
        guard autoRefreshTask == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshModelsQuietly(app) }
        }
        autoRefreshTask = Task { [weak self] in
            await self?.refreshModelsQuietly(app)
            while !Task.isCancelled {
                let pause = self?.quietInterval ?? .seconds(60)
                try? await Task.sleep(for: pause)
                guard !Task.isCancelled else { return }
                guard NSApplication.shared.isActive else { continue }
                await self?.refreshModelsQuietly(app)
            }
        }
    }

    // Обратной операции нет намеренно: модель живёт столько же, сколько окно
    // приложения, и «остановить обновление» было бы кнопкой, которую некому
    // нажать. Задача и наблюдатель уходят вместе с процессом.

    func overrideKind(_ model: LMStudioModel, to kind: LMStudioModelKind, app: AppEnvironment) {
        app.settings.configuration.modelKindOverrides[model.id] = kind.rawValue
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index].kind = kind
            models[index].kindIsInferred = true
        }
        app.log.record(.info, "LM Studio", "Тип модели \(model.id) вручную изменён на «\(kind.title)»")
        overrideWarning = nil
        guard kind == .embedding else { return }
        Task { await verifyEmbeddingOverride(model, app: app) }
    }

    /// Пометка «считать эмбеддинговой» меняет наш список, но не мнение
    /// LM Studio.
    ///
    /// Живой случай: `bge-m3-mlx` числится у LM Studio как `llm` (arch
    /// xlm-roberta), на `/v1/embeddings` она её не подаёт и молча отвечает
    /// от загруженной модели. Пометка при этом ставится, модель появляется
    /// в списках выбора — и узнать о подмене можно было бы только по чужим
    /// векторам в коллекции. Поэтому пометка проверяется сразу одним
    /// вызовом, пока человек ещё смотрит на экран.
    ///
    /// Проба идёт **мимо кэша**: сохранённый вектор ответил бы за модель,
    /// которую сейчас никто не спрашивал.
    private func verifyEmbeddingOverride(_ model: LMStudioModel, app: AppEnvironment) async {
        guard let client = try? app.makeLMStudioClient() else { return }
        do {
            _ = try await client.embedIgnoringCache(texts: ["проверка"], model: model.id)
        } catch let error as LMStudioError {
            switch error {
            case .modelSubstituted, .modelNotEmbedding:
                overrideWarning = error.errorDescription
                app.log.record(.warning, "LM Studio", "Проба пометки «эмбеддинговая» у \(model.id): \(error.errorDescription ?? "")")
            default:
                // LM Studio выключена или занята — это не про пометку, и
                // говорить об этом здесь значило бы обвинить не то.
                break
            }
        } catch {
            return
        }
    }

    func selectDefaultModel(_ model: LMStudioModel, app: AppEnvironment) {
        app.settings.configuration.defaultEmbeddingModel = model.id
        app.log.record(.info, "LM Studio", "Модель по умолчанию: \(model.id)")
    }

    // MARK: - Кэш эмбеддингов

    func refreshCacheStatistics(_ app: AppEnvironment) async {
        cacheStatistics = await app.embeddingCache.statistics()
    }

    func clearCache(_ app: AppEnvironment) async {
        isClearingCache = true
        defer { isClearingCache = false }
        await app.embeddingCache.clear()
        await refreshCacheStatistics(app)
        connectionMessage = String(localized: "Кэш эмбеддингов очищен.")
    }

    func applyCacheLimit(_ app: AppEnvironment, gigabytes: Double) async {
        let bytes = Int64(max(0.1, gigabytes) * 1024 * 1024 * 1024)
        app.settings.configuration.embeddingCacheLimitBytes = bytes
        await app.embeddingCache.setLimit(bytes: bytes)
        await refreshCacheStatistics(app)
    }

    // MARK: - Бенчмарк моделей

    func refreshBenchmarks(_ app: AppEnvironment) async {
        benchmarks = await app.benchmarks.all()
        // Замер — это минуты занятой локальной модели. Если файл замеров не
        // читается, приложение в него ничего и не пишет, и узнать об этом
        // надо до следующего измерения, а не после.
        benchmarksProblem = await app.benchmarks.persistenceProblem()
    }

    func benchmark(for model: String) -> ModelBenchmark? {
        benchmarks.first { $0.model == model }
    }

    /// Asks first. The run holds the model for its whole duration, and the
    /// duration is exactly what the user cannot guess — so it is shown before
    /// the button does anything (rule 4, Приложение 5).
    func requestBenchmark(_ model: LMStudioModel, app: AppEnvironment) async {
        let metrics = await app.metrics.current()
        pendingAction = .benchmark(
            model: model.id,
            estimatedSeconds: ModelBenchmarkService.estimatedSeconds(
                model: model.id, benchmarks: benchmarks, metrics: metrics
            )
        )
    }

    func cancelPendingAction() {
        pendingAction = nil
    }

    // MARK: - Перезагрузка модели с бо́льшим контекстом

    @Published private(set) var loadingModel: String?
    /// Перезагрузка стоит в очереди и ещё не начата.
    ///
    /// Разница видна человеку: «загружается» — это минуты, «ждёт очереди» —
    /// это «сначала доработает то, что идёт». Без этой строки кнопка,
    /// нажатая во время индексации, выглядела бы сломанной.
    @Published private(set) var loadWaitsInQueue = false

    /// Есть ли чем перезагружать. Кнопка без `lms` — обещание, которого
    /// приложение не выполнит.
    ///
    /// `var` ради тестов: условие «без CLI кнопки нет» иначе проверялось бы
    /// тем, стоит ли LM Studio на машине сборки, — то есть не проверялось бы
    /// вовсе.
    var loader = LMStudioLoader()

    /// Стоит ли предлагать перезагрузку этой модели.
    ///
    /// Контекст задаётся при загрузке модели в LM Studio: модель с потолком
    /// 131 072 сплошь и рядом поднята с 8192, и упираются в это именно
    /// порождающие вызовы — чанкинг и переранжирование.
    func reloadableContext(_ model: LMStudioModel) -> (from: Int, to: Int)? {
        guard loader.isAvailable, loadingModel == nil else { return nil }
        guard let loaded = model.loadedContextLength, let maximum = model.contextLength,
              maximum > loaded
        else { return nil }
        return (loaded, maximum)
    }

    func requestLoad(_ model: LMStudioModel) {
        guard let range = reloadableContext(model) else { return }
        pendingAction = .load(model: model.id, from: range.from, to: range.to)
    }

    /// Перезагружает модель и перечитывает список.
    ///
    /// Не через общую очередь задач: очередь распоряжается **работой
    /// приложения**, а это работа LM Studio — она выгрузит модель у всех, кто
    /// ею пользуется, независимо от того, что стоит в очереди здесь. Поэтому
    /// и спрашивается подтверждение.
    func startLoad(_ app: AppEnvironment) {
        guard case .load(let model, let from, let to)? = pendingAction else { return }
        pendingAction = nil
        loadingModel = model
        app.log.record(
            .info, "Модели",
            "Перезагрузка модели «\(model)» с контекстом \(to.plainDigits) вместо \(from.plainDigits)"
        )
        // Через очередь, в группе локальной модели. Раньше
        // перезагрузка шла мимо неё — «это работа LM Studio, а не
        // приложения», — и выдёргивала модель из-под собственного же замера
        // скорости: в журнале это «LM Studio вернула ошибку 400: Model was
        // unloaded while the request was still in queue» и потерянные минуты
        // измерения. Очередь держит группу последовательной, поэтому
        // перезагрузка теперь дожидается конца того, что приложение уже
        // начало. Чужие пользователи LM Studio ею по-прежнему не защищены —
        // на то и спрашивается подтверждение.
        let ticket = QueueTicket(
            title: String(localized: "Перезагрузка модели «\(model)»"),
            priority: .interactive,
            group: .lmStudio,
            connectionID: app.connectionID
        )
        Task {
            defer {
                loadingModel = nil
                loadWaitsInQueue = false
            }
            loadWaitsInQueue = await app.queue.isRunning(group: .lmStudio)
            do {
                // Именно `reload`, а не `load`: `lms load` ставит рядом ещё
                // одну копию модели, а не заменяет загруженную.
                // `loader` копией в список захвата: читать изменяемое
                // свойство главного актора из задачи очереди — это гонка,
                // и в Swift 6 ошибка. Структура Sendable, копия ничего не стоит.
                let result = try await app.queue.run(ticket) { [weak self, loader] _ in
                    await MainActor.run { [weak self] in self?.loadWaitsInQueue = false }
                    return try await loader.reload(model: model, contextLength: to)
                }
                app.log.record(
                    .success, "Модели",
                    "Модель «\(model)» загружена с контекстом \(to.plainDigits)"
                    + (result.unloaded > 0 ? "; выгружено прежних экземпляров: \(result.unloaded)" : "")
                )
                await checkConnection(app, probeUnknownModels: false)
            } catch {
                errorMessage = app.describe(error)
                app.report(error, category: "Модели")
            }
        }
    }

    func cancelBenchmark() {
        benchmarkTask?.cancel()
    }

    func startBenchmark(_ app: AppEnvironment) {
        guard case .benchmark(let model, _)? = pendingAction else { return }
        pendingAction = nil

        let ticket = QueueTicket(
            title: String(localized: "Измерение скорости модели «\(model)»"),
            priority: .manual,
            group: .lmStudio,
            connectionID: app.connectionID
            // Deliberately not resumable: a measurement interrupted halfway is
            // not half a measurement, and offering to «continue» it after a
            // restart would hand back numbers nobody can trust.
        )

        benchmarkTask = Task { [weak self] in
            guard let self else { return }
            self.benchmarkingModel = model
            self.errorMessage = nil
            defer { self.benchmarkingModel = nil }
            do {
                let client = try app.makeLMStudioClient()
                let service = ModelBenchmarkService(provider: client, log: app.logHandler)
                let result = try await app.queue.run(ticket) { context in
                    await app.queue.setCanceller(for: context.id) { [weak self] in
                        Task { @MainActor in self?.cancelBenchmark() }
                    }
                    return try await service.run(model: model) { fraction, detail in
                        await context.report(progress: fraction, detail: detail)
                    }
                }
                await app.benchmarks.store(result)
                await self.refreshBenchmarks(app)
                self.connectionMessage = String(
                    localized: "Модель «\(model)»: \(String(format: "%.1f", result.textsPerSecond)) текстов/с при батче \(result.optimalBatchSize ?? 0), первый вызов \(String(format: "%.2f", result.firstCallSeconds)) с."
                )
                // a measurement of a large model runs for minutes, and the
                // user is invited by the warning itself to go and do something
                // else while it does.
                app.notify(OperationNotice(
                    kind: .benchmark, subject: model,
                    duration: result.batches.reduce(result.firstCallSeconds) { $0 + $1.seconds }
                ))
            } catch is CancellationError {
                app.log.record(.info, "Бенчмарк", "Измерение скорости модели «\(model)» отменено — результат не сохранён")
            } catch {
                self.errorMessage = app.describe(error)
                app.notify(.failure(kind: .benchmark, subject: model, reason: app.describe(error)))
                app.report(error, category: "Бенчмарк")
            }
        }
    }
}
