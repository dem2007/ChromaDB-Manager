import Foundation
import SwiftUI
import ChromaCore

/// Decides *when* sources sync by themselves (substage 2D).
///
/// It only schedules: the run itself goes through `SourcesViewModel.run`, the
/// same path as the manual buttons. Timers live only while the app is running —
/// no launchd agents and no background daemons are installed, which is a stated
/// limitation, not an oversight.
@MainActor
final class AutoSyncCoordinator: ObservableObject {
    /// What the status bar shows while an automatic run is going on.
    @Published private(set) var activity: String?
    /// Next scheduled run per source, so the source card can show it.
    @Published private(set) var nextRun: [UUID: Date] = [:]
    @Published private(set) var queued: [UUID] = []

    private weak var app: AppEnvironment?
    private weak var sources: SourcesViewModel?
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var watchers: [UUID: FolderWatcher] = [:]
    private var lastRun: [UUID: Date] = [:]
    private var isRunning = false
    /// The launch-trigger and folder-watcher runs, which have no timer to hold
    /// them. Without a handle they could not be stopped on quit.
    private var unscheduledWork: [Task<Void, Never>] = []

    // MARK: - Lifecycle

    func start(app: AppEnvironment, sources: SourcesViewModel) {
        self.app = app
        self.sources = sources
        sources.cancelAutomaticWork = { [weak self] in self?.cancelRunningWork() }
        reload()
        track(Task { await runLaunchSyncs() })
    }

    /// Останавливает автоматический прогон, который сейчас идёт, — и **только
    /// его**.
    ///
    /// Раньше первой строкой стояло `cancelAllTimersAndWatchers()`, то есть
    /// «Остановить всё» заодно снимало все таймеры и всё слежение за папками.
    /// Поднимал их обратно только `reload()`, которого после отмены никто
    /// не звал: одно нажатие — и автоматическая индексация мертва до
    /// перезапуска приложения или до правки любого источника. Молча:
    /// об остановке слежения в журнал не писалось ничего.
    ///
    /// «Остановить всё» — про текущую работу. Выключатель автоматики
    /// отдельный, и он называется паузой.
    func cancelRunningWork() {
        for work in unscheduledWork { work.cancel() }
        unscheduledWork.removeAll()
        // Таймеры и слежение поднимаются заново тем же путём, что при запуске:
        // прерванный прогон не повод переставать следить за папкой.
        reload()
    }

    private func track(_ work: Task<Void, Never>) {
        unscheduledWork.removeAll { $0.isCancelled }
        unscheduledWork.append(work)
    }

    /// Re-reads the sources and rebuilds timers and watchers. Called after any
    /// change to the list, and when the global pause is switched.
    func reload() {
        guard let app else { return }
        cancelAllTimersAndWatchers()

        guard !app.settings.configuration.automaticSyncPaused else {
            activity = nil
            nextRun = [:]
            app.log.record(.info, "Источники", "Автоматическая индексация приостановлена — таймеры и слежение за папками остановлены")
            return
        }

        for source in app.settings.configuration.dataSources {
            if source.triggers.scheduled { scheduleNext(for: source) }
            if source.triggers.onFileChanges { startWatching(source) }
        }
    }

    func stop() {
        cancelAllTimersAndWatchers()
        activity = nil
    }

    private func cancelAllTimersAndWatchers() {
        // Пропажа слежения оставляет след: включение писалось в журнал,
        // а выключение — нет, и «почему папка перестала отслеживаться»
        // было нечем ответить.
        if !watchers.isEmpty || !timers.isEmpty {
            app?.log.record(
                .debug, "Источники",
                "Слежение и таймеры остановлены (папок: \(watchers.count), таймеров: \(timers.count))"
            )
        }
        for task in timers.values { task.cancel() }
        timers.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        nextRun = [:]
    }

    // MARK: - Triggers

    private func runLaunchSyncs() async {
        guard let app, !app.settings.configuration.automaticSyncPaused else { return }
        let launchSources = app.settings.configuration.dataSources.filter { $0.triggers.onLaunch }
        guard !launchSources.isEmpty else { return }

        // Deliberately not awaited by the UI: the window opens first and the
        // work shows up in the status bar as it goes.
        for source in launchSources {
            await requestSync(source, reason: .launch)
        }
    }

    private func scheduleNext(for source: DataSource) {
        guard let app else { return }
        guard let fireDate = source.triggers.schedule.nextFireDate(
            after: Date(),
            lastRun: lastRun[source.id] ?? source.lastSyncedAt
        ) else { return }

        nextRun[source.id] = fireDate
        let delay = max(1, fireDate.timeIntervalSinceNow)
        app.log.record(
            .info,
            "Источники",
            "Источник «\(source.name)»: следующая синхронизация \(fireDate.formatted(date: .abbreviated, time: .shortened)) (\(source.triggers.schedule.summary))"
        )

        timers[source.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, let app = self.app else { return }
            // The source may have been edited or removed while we were sleeping.
            guard let current = app.settings.configuration.dataSources.first(where: { $0.id == source.id }),
                  current.triggers.scheduled else { return }
            await self.requestSync(current, reason: .schedule)
            guard !Task.isCancelled else { return }
            self.scheduleNext(for: current)
        }
    }

    private func startWatching(_ source: DataSource) {
        guard let app else { return }
        let watcher = FolderWatcher(url: source.url, debounce: source.triggers.debounceSeconds) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.track(Task { [weak self] in
                    guard let self, let app = self.app else { return }
                    guard let current = app.settings.configuration.dataSources.first(where: { $0.id == source.id }),
                          current.triggers.onFileChanges else { return }
                    await self.requestSync(current, reason: .fileChanges)
                })
            }
        }
        if watcher.start() {
            watchers[source.id] = watcher
            app.log.record(.info, "Источники", "Слежение за папкой источника «\(source.name)» включено (пауза \(Int(source.triggers.debounceSeconds)) с)")
        } else {
            app.log.record(.error, "Источники", "Не удалось начать слежение за папкой источника «\(source.name)» — режим «при изменениях» не работает для него")
        }
    }

    // MARK: - Running

    /// Serialises automatic runs. A second request for a source that is already
    /// syncing is dropped with a log entry — queueing it would only mean running
    /// the same comparison twice in a row.
    private func requestSync(_ source: DataSource, reason: SyncReason) async {
        guard let app, let sources else { return }
        guard !app.settings.configuration.automaticSyncPaused else {
            app.log.record(.info, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) не запущена: автоматическая индексация приостановлена")
            return
        }

        // Starting the server on launch is optional, so a timer or a
        // folder watcher can now fire while nothing is connected.
        guard app.client != nil else {
            app.log.record(.info, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) не запущена: нет подключения к ChromaDB")
            return
        }

        if await app.syncService.isRunning(sourceID: source.id) {
            app.log.record(.warning, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) отброшена: для этого источника она уже идёт")
            return
        }
        // A source whose interrupted run could not be replayed waits for a
        // person: retrying it on a timer would just repeat the same failure and
        // fill the log.
        if let reason = await app.syncService.recoveryBlockReason(sourceID: source.id) {
            app.log.record(
                .warning,
                "Источники",
                "Автоматическая синхронизация «\(source.name)» приостановлена: \(reason). Запустите её вручную, когда причина устранена."
            )
            return
        }
        // ветку переключили — автоматическая переиндексация не
        // запускается. Переключить ветку это обычное рабочее действие, а
        // переиндексация репозитория — часы работы локальной модели. Человеку
        // сказано, сколько файлов разошлось, и решение за ним.
        if source.isGit {
            let status = await app.gitSync.status(of: source)
            if let note = status.branchChangeNote {
                app.log.record(.warning, "Git", "Источник «\(source.name)»: \(note)")
                app.notify(OperationNotice(
                    kind: .sync, subject: source.name, problems: [note]
                ))
                return
            }
        }

        if isRunning || sources.isBusy {
            // Another source is busy; wait rather than have two folders compete
            // for the same model.
            queued.append(source.id)
            app.log.record(.info, "Источники", "Синхронизация «\(source.name)» (\(reason.title)) поставлена в очередь")
            while isRunning || sources.isBusy {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if app.settings.configuration.automaticSyncPaused {
                    queued.removeAll { $0 == source.id }
                    app.log.record(.info, "Источники", "Синхронизация «\(source.name)» снята с очереди: индексация приостановлена")
                    return
                }
            }
            queued.removeAll { $0 == source.id }
        }

        isRunning = true
        activity = String(localized: "Синхронизация «\(source.name)» — \(reason.title)")
        defer {
            isRunning = false
            activity = nil
        }

        lastRun[source.id] = Date()
        let summary = await sources.run(source, app: app, reason: reason)
        if let summary, !summary.needsDecision.isEmpty {
            // Automatic modes never delete: the list only grows and waits.
            app.log.record(
                .warning,
                "Источники",
                "«\(source.name)»: файлов, требующих решения — \(summary.needsDecision.count). Автоматически из базы ничего не удалено."
            )
        }
    }

    /// Toggles the global pause and rebuilds everything accordingly.
    func setPaused(_ paused: Bool, app: AppEnvironment) {
        app.settings.configuration.automaticSyncPaused = paused
        // the global pause of 8.4 is the queue's pause. Interactive work
        // still goes through — see.
        app.setQueuePaused(paused)
        if paused {
            app.log.record(.warning, "Источники", "Вся автоматическая индексация приостановлена пользователем")
        } else {
            app.log.record(.info, "Источники", "Автоматическая индексация возобновлена")
        }
        reload()
    }
}
