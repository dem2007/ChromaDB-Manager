import Foundation
import AppKit
import ChromaCore

/// Drives «Статус окружения»: probing, installing, upgrading with a mandatory
/// backup, and restoring one when an upgrade goes wrong.
@MainActor
final class EnvironmentViewModel: ObservableObject {
    @Published var isBusy = false
    @Published var busyTitle = ""
    @Published var consoleLines: [String] = []
    @Published var errorMessage: String?
    @Published var hint: String?
    @Published var infoMessage: String?

    // Install path A
    @Published var standalonePlan: StandaloneInstallPlan?
    @Published var showStandaloneConfirmation = false

    // Upgrade
    @Published var showUpgradeSheet = false
    /// Backups are mandatory; skipping one takes a conscious extra click.
    @Published var acknowledgeSkippingBackup = false
    @Published var lastBackup: BackupRecord?
    @Published var backups: [BackupRecord] = []
    /// Копия, о которой спрошено «точно удалить».
    ///
    /// Удаление копии необратимо и стоит ровно один щелчок по значку корзины,
    /// стоящему в ряду с «Восстановить». Промах по соседней кнопке уносил
    /// последнюю копию базы на пять гигабайт, и узнать об этом можно было
    /// только по исчезнувшей строке.
    @Published var pendingBackupDeletion: BackupRecord?
    /// Whether the installed CLI has the vacuum command. Probed once.
    @Published var maintenanceAvailable = false
    @Published var lastMaintenance: MaintenanceService.Result?
    @Published var wipeIncludesBackups = false
    @Published var wipeConfirmation = ""
    @Published var verificationFailed = false
    @Published var countsBefore: [String: Int] = [:]

    private var task: Task<Void, Never>?

    // MARK: - Probe

    func refresh(_ app: AppEnvironment, checkUpdates: Bool? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        busyTitle = String(localized: "Проверка окружения…")
        defer { isBusy = false; busyTitle = "" }
        await app.refreshEnvironment(checkUpdates: checkUpdates)
        backups = app.backupService.list()
    }

    // MARK: - Обновления приложения

    /// Итог последней проверки. `nil` — ещё не проверяли: это третье
    /// состояние, и показывать его как «актуальна» было бы враньём.
    @Published var appUpdate: AppUpdateOutcome?
    @Published var isCheckingAppUpdate = false
    @Published var appUpdateError: String?

    /// Спрашивает GitHub о новой версии приложения.
    ///
    /// `automatic` отличает проверку при запуске от нажатия кнопки: молчаливая
    /// проверка не должна выводить сообщение об ошибке поверх экрана, с которым
    /// человек работает. Ошибку она пишет в журнал и остаётся ни с чем —
    /// недоступный GitHub не повод беспокоить.
    func checkAppUpdates(_ app: AppEnvironment, automatic: Bool = false) async {
        guard !isCheckingAppUpdate else { return }
        isCheckingAppUpdate = true
        appUpdateError = nil
        defer { isCheckingAppUpdate = false }
        do {
            let outcome = try await AppUpdateChecker().check()
            appUpdate = outcome
            switch outcome {
            case .available(let release, let current):
                app.logHandler(.info, "Приложение", "Доступна версия \(release.version) (установлена \(current))")
            case .upToDate(let current):
                app.logHandler(.info, "Приложение", "Установлена последняя версия: \(current)")
            case .unknownCurrentVersion:
                app.logHandler(.info, "Приложение", "Версия приложения неизвестна — сборка запущена не из бандла")
            }
        } catch {
            app.logHandler(.warning, "Приложение", "Не удалось проверить обновления: \(error.localizedDescription)")
            if !automatic { appUpdateError = app.describe(error) }
        }
    }

    func openReleasePage(_ release: AppRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    /// Explicit user action: this is the only place that reaches the network
    /// for version information.
    func checkForUpdates(_ app: AppEnvironment) {
        run(app, title: String(localized: "Проверка обновлений")) {
            var status = app.environmentStatus
            await app.inspector.checkForUpdates(&status)
            await MainActor.run {
                app.environmentStatus = status
                self.infoMessage = status.updateAvailable
                    ? String(localized: "Доступна версия \(status.latestVersion ?? "?") (установлена \(status.installedVersion ?? "?")).")
                    : String(localized: "Установлена актуальная версия.")
            }
        }
    }

    // MARK: - Install path A — standalone CLI

    /// Resolves the download and shows it to the user; nothing is fetched until
    /// they confirm.
    func prepareStandaloneInstall(_ app: AppEnvironment) {
        run(app, title: String(localized: "Подготовка установки")) {
            let plan = try await app.installer.planStandaloneInstall()
            await MainActor.run {
                self.standalonePlan = plan
                self.showStandaloneConfirmation = true
            }
        }
    }

    func confirmStandaloneInstall(_ app: AppEnvironment) {
        guard let plan = standalonePlan else { return }
        showStandaloneConfirmation = false
        run(app, title: String(localized: "Установка Chroma CLI")) { [weak self] in
            try await app.installer.installStandalone(plan: plan) { line in
                Task { @MainActor in self?.appendConsole(line) }
            }
            await app.refreshEnvironment(checkUpdates: false)
            await MainActor.run {
                self?.infoMessage = String(localized: "Chroma CLI \(plan.version) установлен.")
                app.settings.configuration.preferredInstallPath = .standalone
            }
        }
    }

    // MARK: - Install path B — managed venv

    func installIntoVenv(_ app: AppEnvironment, upgrade: Bool = false) {
        let base = app.environmentStatus.interpreters.first { !$0.isManagedVenv }
        run(app, title: upgrade ? String(localized: "Обновление пакета chromadb") : String(localized: "Установка пакета chromadb")) { [weak self] in
            try await app.installer.installIntoVenv(upgrade: upgrade, baseInterpreter: base) { line in
                Task { @MainActor in self?.appendConsole(line) }
            }
            await app.refreshEnvironment(checkUpdates: false)
            await MainActor.run {
                app.settings.configuration.preferredInstallPath = .managedVenv
                self?.infoMessage = String(localized: "Готово: \(app.environmentStatus.chromaCLIVersion ?? "движок установлен").")
            }
        }
    }

    func installPythonWithHomebrew(_ app: AppEnvironment) {
        run(app, title: String(localized: "Установка Python через Homebrew")) { [weak self] in
            try await app.installer.installPythonViaHomebrew { line in
                Task { @MainActor in self?.appendConsole(line) }
            }
            await app.refreshEnvironment(checkUpdates: false)
        }
    }

    func openPythonDownloadPage() {
        NSWorkspace.shared.open(InstallationService.pythonDownloadURL)
    }

    func openInstallScriptPage() {
        NSWorkspace.shared.open(InstallationService.officialInstallScriptURL)
    }

    func bootstrapPip(_ app: AppEnvironment) {
        guard let interpreter = app.environmentStatus.activeInterpreter else { return }
        run(app, title: String(localized: "Восстановление pip")) { [weak self] in
            try await app.installer.bootstrapPip(using: interpreter) { line in
                Task { @MainActor in self?.appendConsole(line) }
            }
            await app.refreshEnvironment(checkUpdates: false)
        }
    }

    // MARK: - Upgrade with data safety

    /// Storage-format migrations run automatically and cannot be undone, so the
    /// order is: snapshot counts → stop server → back up → upgrade → verify.
    func upgrade(_ app: AppEnvironment) {
        showUpgradeSheet = false
        let makeBackup = !acknowledgeSkippingBackup
        let databaseURL = backupTarget(app)
        let previousVersion = app.environmentStatus.installedVersion ?? "?"
        // Follow the switch the user just set, not whatever happens to be
        // installed: choosing «Автономный CLI» and pressing «Обновить» has to
        // deliver the binary, not a pip upgrade of the venv package.
        let usesVenv = app.settings.configuration.preferredInstallPath == .managedVenv

        run(app, title: String(localized: "Обновление движка")) { [weak self] in
            guard let self else { return }

            // 1. Remember what the database looked like before.
            if let client = app.client {
                let collections = (try? await client.listCollections(withCounts: true)) ?? []
                let snapshot = Dictionary(uniqueKeysWithValues: collections.map { ($0.name, $0.documentCount ?? 0) })
                await MainActor.run {
                    self.countsBefore = snapshot
                    self.appendConsole("Зафиксировано коллекций: \(snapshot.count), документов: \(snapshot.values.reduce(0, +))")
                }
            }

            // 2. The database must be closed before its files are copied.
            if app.processManager.isRunning || app.connection.isConnected {
                await MainActor.run { self.appendConsole("Останавливаем сервер перед обновлением…") }
                await app.disconnect(reason: .serverRestart)
            }

            // 3. Backup.
            if makeBackup, let databaseURL {
                let inspection = await app.inspector.databaseDirectoryInfo(databaseURL)
                if inspection.exists {
                    await MainActor.run { self.appendConsole("Резервная копия: \(databaseURL.path)") }
                    let record = try app.backupService.backup(
                        databaseAt: databaseURL,
                        note: "перед обновлением движка \(previousVersion)"
                    )
                    await MainActor.run {
                        self.lastBackup = record
                        self.appendConsole("Создана копия \(record.name) (\(record.sizeText))")
                    }
                } else {
                    await MainActor.run { self.appendConsole("Каталог базы пуст — копировать нечего.") }
                }
            } else if makeBackup {
                await MainActor.run {
                    self.appendConsole("Внешний сервер: файлы базы недоступны приложению, копия не создаётся.")
                }
            }

            // 4. Upgrade.
            if usesVenv {
                try await app.installer.installIntoVenv(upgrade: true, baseInterpreter: nil) { line in
                    Task { @MainActor in self.appendConsole(line) }
                }
            } else {
                let plan = try await app.installer.planStandaloneInstall()
                try await app.installer.installStandalone(plan: plan) { line in
                    Task { @MainActor in self.appendConsole(line) }
                }
            }

            await app.refreshEnvironment(checkUpdates: true)
            let newVersion = app.environmentStatus.installedVersion ?? "?"
            await MainActor.run {
                self.appendConsole(newVersion == previousVersion
                    ? "Версия не изменилась: \(newVersion)"
                    : "Версия обновлена: \(previousVersion) → \(newVersion)")
            }

            // 5. Verify: the database must open and hold the same documents.
            await MainActor.run { self.appendConsole("Проверяем, что база открывается…") }
            await app.connect()
            guard let client = app.client else {
                await MainActor.run {
                    self.verificationFailed = true
                    self.errorMessage = String(localized: "После обновления не удалось подключиться к базе.")
                }
                return
            }
            do {
                let collections = try await client.listCollections(withCounts: true)
                let after = Dictionary(uniqueKeysWithValues: collections.map { ($0.name, $0.documentCount ?? 0) })
                let mismatches = self.countsBefore.filter { after[$0.key] != $0.value }
                await MainActor.run {
                    if self.countsBefore.isEmpty {
                        self.appendConsole("✅ База открывается, коллекций: \(after.count)")
                        self.infoMessage = String(localized: "Обновление завершено. Версия \(newVersion).")
                    } else if mismatches.isEmpty {
                        self.appendConsole("✅ Коллекции и счётчики совпадают с зафиксированными до обновления")
                        self.infoMessage = String(localized: "Обновление завершено. Версия \(newVersion), коллекций: \(after.count).")
                    } else {
                        self.verificationFailed = true
                        let detail = mismatches.map { "\($0.key): было \($0.value), стало \(after[$0.key] ?? 0)" }.joined(separator: "; ")
                        self.appendConsole("❌ Расхождение после обновления — \(detail)")
                        self.errorMessage = String(localized: "После обновления данные не совпадают: \(detail)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.verificationFailed = true
                    self.errorMessage = app.describe(error)
                    self.appendConsole("❌ Проверка не пройдена: \(app.describe(error))")
                }
            }
        }
    }

    /// Which directory can be copied: only databases whose files we can reach.
    /// Space needed against space available, for the backups card.
    func backupSpace(_ app: AppEnvironment) -> BackupService.SpaceCheck? {
        guard let target = backupTarget(app),
              FileManager.default.fileExists(atPath: target.path) else { return nil }
        return app.backupService.spaceCheck(for: target)
    }

    func databaseSize(_ app: AppEnvironment) -> Int64 {
        guard let target = backupTarget(app) else { return 0 }
        return app.backupService.directorySize(target)
    }

    /// Asked once, when the screen appears: a version without the command must
    /// not show a button at all.
    func probeMaintenance(_ app: AppEnvironment) async {
        maintenanceAvailable = await app.maintenance.isAvailable()
    }

    /// Backup → stop → vacuum → start → verify, in that order.
    ///
    /// Целиком — **задачей общей очереди** в группе `exclusive`.
    /// Сжатие копирует базу и гасит сервер, а гашение снимает все задачи
    /// подключения: ровно та беда, что разобрана в для бэкапа. До этой
    /// правки сжатие шло мимо очереди, и нажатое во время индексации
    /// обрывало её молча — а само оно нигде, кроме этого экрана, не значилось,
    /// так что «почему всё встало» ответа не имело.
    func runMaintenance(_ app: AppEnvironment) {
        guard let target = backupTarget(app) else { return }
        run(app, title: String(localized: "Обслуживание базы")) { [weak self] in
            let ticket = QueueTicket(
                title: String(localized: "Сжатие базы"),
                priority: .interactive,
                group: .exclusive,
                connectionID: nil
            )
            try await app.queue.run(ticket) { _ in
                await MainActor.run { self?.appendConsole("Резервная копия перед обслуживанием…") }
                let record = try app.backupService.backup(databaseAt: target, note: "перед обслуживанием базы")
                await MainActor.run {
                    self?.lastBackup = record
                    self?.appendConsole("Создана копия \(record.name) (\(record.sizeText))")
                }

                let collectionsBefore = await app.collectionSnapshots().count
                await MainActor.run { self?.appendConsole("Останавливаем сервер…") }
                await app.disconnect(reason: .serverRestart)

                let result: MaintenanceService.Result
                do {
                    result = try await app.maintenance.vacuum(databaseAt: target)
                } catch {
                    // Сервер поднимается, чем бы сжатие ни кончилось: оставить
                    // базу погашенной значило бы к неудачной операции добавить
                    // неработающее приложение.
                    await app.connect()
                    throw error
                }
                await MainActor.run {
                    self?.lastMaintenance = result
                    self?.appendConsole(result.summary)
                }

                await app.connect()
                // The check that matters: the database opens and still has
                // everything it had before.
                let collectionsAfter = await app.collectionSnapshots().count
                await MainActor.run {
                    if collectionsAfter == collectionsBefore {
                        self?.appendConsole("Проверка после обслуживания: коллекций \(collectionsAfter), как и было.")
                        self?.infoMessage = result.summary
                    } else {
                        self?.errorMessage = String(localized: "После обслуживания число коллекций изменилось: было \(collectionsBefore), стало \(collectionsAfter). Резервная копия \(record.name) на месте.")
                    }
                    self?.refreshBackups(app)
                }
            }
        }
    }

    // MARK: - Wiping the app's own data

    func wipePlan(_ app: AppEnvironment) -> [DataWipeService.Item] {
        app.dataWipe.plan()
    }

    func wipeUntouchedPaths(_ app: AppEnvironment) -> [String] {
        let profilePaths = app.settings.configuration.serverProfiles
            .compactMap(\.databasePath)
            .map { URL(fileURLWithPath: $0) }
        return app.dataWipe.untouched(localDatabasePath: app.localDatabaseURL, profilePaths: profilePaths)
    }

    func wipeAllData(_ app: AppEnvironment) {
        let includingBackups = wipeIncludesBackups
        run(app, title: String(localized: "Удаление данных приложения")) { [weak self] in
            // Nothing may still be writing into the folders about to go.
            await app.disconnect()
            await MainActor.run { self?.appendConsole("Все процессы остановлены.") }
            let removed = app.dataWipe.wipe(includingBackups: includingBackups)
            await MainActor.run {
                for path in removed { self?.appendConsole("Удалено: \(path)") }
                self?.wipeConfirmation = ""
                self?.infoMessage = String(localized: "Данные приложения удалены (\(removed.count) объектов). Закройте приложение — при следующем запуске оно начнёт с чистой конфигурации.")
                self?.refreshBackups(app)
            }
        }
    }

    func backupTarget(_ app: AppEnvironment) -> URL? {
        switch app.settings.configuration.mode {
        case .localDatabase:
            return app.localDatabaseURL
        case .server:
            guard let profile = app.settings.activeProfile,
                  profile.kind == .managed,
                  let path = profile.databasePath else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    // MARK: - Backups

    func refreshBackups(_ app: AppEnvironment) {
        backups = app.backupService.list()
    }

    func restore(_ backup: BackupRecord, app: AppEnvironment) {
        guard let destination = backupTarget(app) else {
            errorMessage = String(localized: "Восстанавливать некуда: активен внешний сервер, его файлы приложению недоступны.")
            return
        }
        run(app, title: String(localized: "Восстановление резервной копии")) { [weak self] in
            // Через общую очередь и в одиночку: восстановление гасит
            // сервер и подменяет файлы базы под всеми, кто с ней работает.
            let ticket = QueueTicket(
                title: String(localized: "Восстановление копии базы"),
                priority: .interactive, group: .exclusive, connectionID: nil
            )
            try await app.queue.run(ticket) { _ in
                await app.disconnect(reason: .serverRestart)
                do {
                    try app.backupService.restore(backup, to: destination)
                } catch {
                    await app.connect()
                    throw error
                }
                await MainActor.run {
                    self?.appendConsole("Копия \(backup.name) восстановлена в \(destination.path)")
                    self?.verificationFailed = false
                    self?.infoMessage = String(localized: "Резервная копия восстановлена.")
                    self?.refreshBackups(app)
                }
                await app.connect()
            }
        }
    }

    func makeBackupNow(_ app: AppEnvironment) {
        guard let target = backupTarget(app) else {
            errorMessage = String(localized: "Для внешнего сервера файловая копия недоступна.")
            return
        }
        run(app, title: String(localized: "Резервное копирование")) { [weak self] in
            // Той же дорогой, что и копия перед переизвлечением (
            //): гашение сервера снимает все задачи подключения, поэтому
            // копирование ждёт пустой очереди и никого не пускает, пока идёт.
            let ticket = QueueTicket(
                title: String(localized: "Резервная копия базы"),
                priority: .interactive, group: .exclusive, connectionID: nil
            )
            try await app.queue.run(ticket) { _ in
                // A copy of a live SQLite database is a corrupt copy.
                await app.disconnect(reason: .serverRestart)
                let record: BackupRecord
                do {
                    record = try app.backupService.backup(databaseAt: target, note: "по запросу пользователя")
                } catch {
                    await app.connect()
                    throw error
                }
                await MainActor.run {
                    self?.lastBackup = record
                    self?.infoMessage = String(localized: "Создана копия \(record.name) (\(record.sizeText)).")
                    self?.refreshBackups(app)
                }
                await app.connect()
            }
        }
    }

    /// Спрашивает, точно ли удалять копию. Сама не удаляет ничего.
    func askToDelete(_ backup: BackupRecord) {
        pendingBackupDeletion = backup
    }

    func delete(_ backup: BackupRecord, app: AppEnvironment) {
        pendingBackupDeletion = nil
        do {
            try app.backupService.delete(backup)
            // Не молча: строка исчезла бы и без сообщения, а «что именно
            // я сейчас удалил» — это ровно то, что человек перепроверяет.
            infoMessage = String(localized: "Копия \(backup.name) удалена (освобождено \(backup.sizeText)).")
            app.log.record(.warning, "Копии", "Резервная копия \(backup.name) удалена вручную (\(backup.sizeText))")
            refreshBackups(app)
        } catch {
            errorMessage = app.describe(error)
        }
    }

    // MARK: - Infrastructure

    func cancel() {
        task?.cancel()
        task = nil
        isBusy = false
        busyTitle = ""
        appendConsole("— операция отменена пользователем —")
    }

    func clearConsole() { consoleLines.removeAll() }

    private func appendConsole(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > 2000 { consoleLines.removeFirst(consoleLines.count - 2000) }
    }

    private func run(_ app: AppEnvironment, title: String, _ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        busyTitle = title
        errorMessage = nil
        infoMessage = nil
        appendConsole("=== \(title) ===")

        task = Task { [weak self] in
            do {
                try await operation()
            } catch {
                await MainActor.run {
                    self?.errorMessage = app.describe(error)
                    if let installationError = error as? InstallationError, !installationError.rawOutput.isEmpty {
                        self?.appendConsole(String(installationError.rawOutput.suffix(2000)))
                    }
                    self?.appendConsole("❌ \(app.describe(error))")
                }
                app.report(error, category: "Окружение")
            }
            await MainActor.run {
                self?.isBusy = false
                self?.busyTitle = ""
            }
        }
    }
}
