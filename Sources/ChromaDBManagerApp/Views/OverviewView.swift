import SwiftUI
import AppKit
import ChromaCore

/// Экран «Обзор», вкладка «Состояние».
///
/// Первое, что видно при запуске, и единственный экран, отвечающий на вопрос
/// «что сейчас с базой». Раньше ответ собирался из трёх разделов: адрес — в
/// «Подключении», процесс — в «Сервере», прокси — в «Безопасности». Человек
/// узнавал, что что-то не работает, случайно.
///
/// Экран **только показывает**: ни одной операции он сам не начинает, кроме
/// тех, что и так есть на соседних вкладках. Каждая строка ведёт туда, где
/// это можно изменить. Язык интерфейса отсюда уехал в «Настройки».
struct OverviewView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var processManager: ChromaProcessManager
    @ObservedObject var server: ServerViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel
    @ObservedObject var environment: EnvironmentViewModel
    @ObservedObject var sources: SourcesViewModel
    /// Размер кэша векторов в сводке. Считает его та же модель, что и на
    /// экране «Модели», — число одно на приложение, а не два своих.
    @ObservedObject var embeddings: EmbeddingsViewModel
    @ObservedObject var diskUsage: DiskUsageViewModel
    /// Куда уйти, если человек решит закрыть находку. Экран не чинит сам —
    /// он показывает и провожает туда, где чинят.
    var go: (SidebarSection, Int?) -> Void = { _, _ in }
    @State private var confirmingServerStop = false

    var body: some View {
        Form {
            summarySection
            nowSection
            // Процесс от прошлой сессии — рядом с фактами о сервере и до
            // списка решений: он держит порт и базу. Секций нет,
            // когда таких процессов нет.
            ChromaProcessesCard(serverModel: server)
            decisionsSection
            // Место на диске — последним: справка, а не то, с чем идут
            // на экран первым делом.
            DiskUsageSection(
                diskUsage: diskUsage, environment: environment,
                cacheFileBytes: embeddings.cacheStatistics?.fileBytes, go: go
            )
        }
        .formStyle(.grouped)
        .task {
            diskUsage.measureIfNeeded(app)
            await embeddings.refreshCacheStatistics(app)
        }
        // Пересчёт — после того, что меняет объём: копии, корзины, кэша.
        .onChange(of: environment.backups.map(\.url)) { _, _ in diskUsage.measure(app) }
        .onReceive(app.trash.$entries.map(\.count).removeDuplicates().dropFirst()) { _ in diskUsage.measure(app) }
        .onChange(of: embeddings.cacheStatistics?.fileBytes) { _, _ in diskUsage.measure(app) }
        // Другая база — другие числа: переключили режим или профиль сервера.
        .onChange(of: EnvironmentViewModel.databaseFolder(app)?.path) { _, _ in diskUsage.measure(app) }
    }

    // MARK: - Сводка

    /// Сколько всего — три числа. Список коллекций живёт на своём экране
    /// целиком, здесь от него нужен только счёт (правило 2). Кэш векторов —
    /// в «Месте на диске», рядом с остальным, что занимает место.
    private var summarySection: some View {
        Section {
            LabeledContent(String(localized: "Коллекций"), value: collectionsModel.collections.count.formatted())
            LabeledContent(String(localized: "Документов"), value: documentsValue)
            LabeledContent(String(localized: "Источников"), value: settings.configuration.dataSources.count.formatted())
        } header: {
            Text("Сводка")
        }
        .monospacedDigit()
    }

    /// Пока число документов коллекции не пришло, оно `nil`, а не ноль:
    /// сложить их значит объявить пустыми те, о которых мы ещё не спросили.
    private var documentsValue: String {
        let known = collectionsModel.collections.compactMap(\.documentCount)
        guard !known.isEmpty else { return "—" }
        // Числа известны не у всех коллекций: сумма — нижняя граница,
        // и это видно, а не подаётся как итог.
        let total = known.reduce(0, +).formatted()
        return known.count < collectionsModel.collections.count ? "≥ \(total)" : total
    }

    // MARK: - Сейчас

    /// Управление процессом — строкой под ним (v6 B1: вкладки «Сервер» больше
    /// нет). Ошибка и итог действия — здесь же, а вопрос об остановке — на
    /// самой кнопке: на секции формы он не открывается.
    @ViewBuilder
    private var serverControls: some View {
        if let error = server.errorMessage {
            LabeledContent {
                Button(String(localized: "Скрыть")) { server.errorMessage = nil }
                    .buttonStyle(.borderless)
            } label: {
                Notice(.warning, error)
            }
        }
        if let status = server.statusMessage {
            LabeledContent {
                Button(String(localized: "Скрыть")) { server.statusMessage = nil }
                    .buttonStyle(.borderless)
            } label: {
                Notice(.info, status)
            }
        }
        HStack {
            Spacer()
            if server.isBusy { ProgressView().controlSize(.small) }
            if processManager.isRunning {
                Button(String(localized: "Перезапустить")) {
                    Task { await server.restart(app, collectionsModel: collectionsModel) }
                }
                Button(String(localized: "Остановить…"), role: .destructive) { confirmingServerStop = true }
                    .confirmationDialog(
                        String(localized: "Остановить сервер ChromaDB?"),
                        isPresented: $confirmingServerStop
                    ) {
                        Button(String(localized: "Остановить"), role: .destructive) {
                            Task { await server.stop(app) }
                        }
                        Button(String(localized: "Отменить"), role: .cancel) {}
                    } message: {
                        Text("Пока сервер стоит, недоступны коллекции, поиск и агенты. Данные не трогаются: база — это папка на диске.")
                    }
            } else {
                Button(String(localized: "Запустить")) {
                    Task { await server.start(app, collectionsModel: collectionsModel) }
                }
            }
        }
        .disabled(server.isBusy)
    }

    /// Строки стоят всегда и в одну строку каждая: значения меняются
    /// сами — аптайм тикает, адрес появляется по подключении, сервер
    /// отвечает про телеметрию когда ответит, — и секция не должна от этого
    /// расти и уводить вниз всё, что под ней.
    private var nowSection: some View {
        Section {
            LabeledContent(String(localized: "Сервер ChromaDB")) {
                StatusLabel(processManager.isRunning ? .ok : .off, serverValue)
                    .lineLimit(1)
            }
            serverControls
            LabeledContent(String(localized: "Прокси")) {
                StatusLabel(app.proxy.state.isRunning ? .ok : .off, proxyValue)
                    .lineLimit(1)
            }
            LabeledContent(String(localized: "Адрес")) {
                monospaced(addressValue)
            }
            LabeledContent(String(localized: "Папка базы")) {
                monospaced(app.localDatabaseURL.path)
            }
            .contextMenu {
                Button(String(localized: "Показать в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([app.localDatabaseURL])
                }
            }
            LabeledContent(String(localized: "Режим"), value: settings.configuration.mode.title)
            if let backup = lastBackup {
                LabeledContent(String(localized: "Резервная копия")) {
                    Button("\(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(backup.sizeText)") {
                        go(.environment, SidebarSection.environment.tabIndex(String(localized: "Резервные копии")))
                    }
                    .buttonStyle(.link)
                    .help(String(localized: "Открыть «Резервные копии»"))
                }
            }
            // Пределы записи — ответ сервера, а не настройка: здесь, а не в
            // «Для опытных» рядом с редактируемыми полями (v4 A5).
            writeLimitRows
            // Своими словами, а сообщение сервера — в подсказке: сырая
            // английская строка движка — не текст интерфейса.
            LabeledContent(String(localized: "Телеметрия")) {
                Text(telemetryValue)
                    .lineLimit(1)
                    .help(processManager.telemetryStatus ?? "")
            }
        } header: {
            SectionHeader(
                String(localized: "Сейчас"),
                help: String(localized: "Приложение само запускает процесс chroma и подключается к нему. Прокси — отдельный слой: только через него к базе ходят внешние клиенты. Сам ChromaDB всегда остаётся на 127.0.0.1.")
            )
        }
    }

    private func monospaced(_ value: String) -> some View {
        Text(value)
            .font(.body.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .copyable(value)
            .help(value)
    }

    /// «Работает (PID 12152) · 4:12:03» — процесс, его номер и сколько он
    /// держится. PID уже в `state.title`, второй раз не добавляется.
    private var serverValue: String {
        guard processManager.isRunning else { return String(localized: "Остановлен") }
        var parts = [processManager.state.title]
        if let uptime = processManager.uptime { parts.append(RootView.uptimeText(uptime)) }
        return parts.joined(separator: " · ")
    }

    private var proxyValue: String {
        guard app.proxy.state.isRunning else {
            return String(localized: "Остановлен · порт \(settings.configuration.proxyPort.plainDigits)")
        }
        return String(localized: "Работает · порт \(settings.configuration.proxyPort.plainDigits)")
    }

    private var addressValue: String {
        if case .connected(let address, _, _, _) = app.connection { return address }
        return String(localized: "нет подключения")
    }

    /// Что сервер разрешает в одном запросе на запись. Показывается, потому
    /// что запасное значение — догадка: окажись оно выше настоящего предела,
    /// сбой случится много позже, посреди импорта.
    @ViewBuilder
    private var writeLimitRows: some View {
        if let limits = app.writeLimits {
            LabeledContent(String(localized: "Записей в одном запросе")) {
                if limits.isReportedByServer {
                    Text(limits.maxRecords.formatted())
                        .monospacedDigit()
                        .help(String(localized: "По данным сервера"))
                } else {
                    StatusLabel(.warning, String(localized: "\(limits.maxRecords.plainDigits), безопасное значение"))
                        .help(String(localized: "Сервер не сообщил предел — используется значение, которое заведомо проходит."))
                }
            }
            LabeledContent(
                String(localized: "Размер одного запроса"),
                value: Int64(limits.maxBodyBytes).formatted(.byteCount(style: .binary))
            )
        }
    }

    /// Что сервер сказал о телеметрии — своими словами.
    private var telemetryValue: String {
        guard let status = processManager.telemetryStatus else {
            return String(localized: "сервер ещё не отвечал")
        }
        return status.localizedCaseInsensitiveContains("no telemetry")
            ? String(localized: "не собирается")
            : String(localized: "см. сообщение сервера")
    }

    // MARK: - Требует решения

    /// Что стоит закрыть — и ничего больше.
    ///
    /// Список собирается из того, что приложение и так знает; ни одной
    /// проверки ради этой карточки не запускается. Пусто — значит пусто:
    /// карточка говорит «всё в порядке» одной строкой, а не показывает
    /// выдуманные пункты, лишь бы не пустовать.
    private struct Decision: Identifiable {
        let id: String
        let text: String
        let isUrgent: Bool
        let action: String?
        let go: (() -> Void)?
    }

    /// Копия старше недели — уже повод сделать новую.
    private static let backupIsStaleAfter: TimeInterval = 7 * 24 * 60 * 60

    private var lastBackup: BackupRecord? {
        environment.backups.first(where: { !$0.isIncomplete })
    }

    private var decisions: [Decision] {
        var found: [Decision] = []

        // Первый запуск — цепочкой, по звену за раз.
        //
        // Отдельного мастера для этого нет и не будет: мастер — это второй
        // сквозной путь через приложение, свои экраны, которые начнут
        // расходиться с основными. Да и показывается он один раз, а «нечем
        // работать» случается и на второй машине, и после переустановки
        // движка, и когда база отвалилась через полгода.
        //
        // Звенья показываются **по одному**: пока не установлен движок,
        // «нет подключения» — не решение, а следствие, и предлагать его
        // значит отправлять человека туда, где ему нечего нажать.
        if app.environmentStatus.checkedAt != nil, !app.environmentStatus.isEngineInstalled {
            found.append(Decision(
                id: "engine",
                text: String(localized: "Движок ChromaDB не установлен — без него нет ни базы, ни поиска"),
                isUrgent: true,
                action: String(localized: "Установка"),
                go: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Установка"))) }
            ))
        } else if !app.connection.isConnected {
            found.append(Decision(
                id: "connection",
                text: String(localized: "Нет подключения к базе — коллекции и поиск недоступны"),
                isUrgent: true,
                action: String(localized: "Подключение"),
                go: { go(.overview, SidebarSection.overview.tabIndex(String(localized: "Подключение"))) }
            ))
        } else if collectionsModel.collections.isEmpty, !collectionsModel.isLoadingCollections {
            // Подключились, а в базе пусто: следующий шаг — не «настроить
            // поиск», а завести источник. Коллекцию создаст он сам, и звать
            // человека делать её руками значит звать на лишнюю работу.
            found.append(Decision(
                id: "empty-database",
                text: String(localized: "В базе нет ни одной коллекции — добавьте источник, он её и создаст"),
                isUrgent: false,
                action: String(localized: "Источники"),
                go: { go(.sources, nil) }
            ))
        } else if settings.configuration.dataSources.isEmpty {
            // Коллекции есть, а источников нет: база наполнена не отсюда —
            // руками, импортом, чужим клиентом. Это не дефект, но и не то
            // состояние, в котором приложение делает свою работу.
            found.append(Decision(
                id: "no-sources",
                text: String(localized: "Источников нет — коллекции наполнены не приложением, обновлять их некому"),
                isUrgent: false,
                action: String(localized: "Источники"),
                go: { go(.sources, nil) }
            ))
        }
        if diskUsage.report?.nextBackupFits == false {
            found.append(Decision(
                id: "disk-space",
                text: String(localized: "Свободного места меньше, чем занимает база, — следующая резервная копия не поместится"),
                isUrgent: true,
                action: String(localized: "Резервные копии"),
                go: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Резервные копии"))) }
            ))
        }
        if sources.problemCount > 0 {
            found.append(Decision(
                id: "sources",
                text: String(localized: "Файлов, которые не удалось прочитать: \(sources.problemCount.plainDigits)"),
                isUrgent: true,
                action: String(localized: "Источники"),
                go: { go(.sources, nil) }
            ))
        }
        if app.proxy.exposure.isExposed {
            found.append(Decision(
                id: "exposure",
                text: String(localized: "Прокси открыт в сеть — к базе может обратиться не только эта машина"),
                isUrgent: true,
                action: String(localized: "Безопасность"),
                go: { go(.security, nil) }
            ))
        }
        if settings.configuration.externalClients.isEmpty {
            found.append(Decision(
                id: "clients",
                text: String(localized: "Ключей клиентов нет — прокси отклоняет все запросы"),
                isUrgent: false,
                action: String(localized: "Клиенты"),
                go: { go(.clients, nil) }
            ))
        }
        // Свежая копия ничего не требует — она строкой в «Сейчас» (v6);
        // здесь — только устаревшая или отсутствующая.
        if let backup = lastBackup {
            if Date().timeIntervalSince(backup.createdAt) > Self.backupIsStaleAfter {
                found.append(Decision(
                    id: "backup",
                    text: String(localized: "Последняя резервная копия — \(backup.createdAt.formatted(.relative(presentation: .named))), \(backup.sizeText)"),
                    isUrgent: false,
                    action: String(localized: "Резервные копии"),
                    go: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Резервные копии"))) }
                ))
            }
        } else {
            found.append(Decision(
                id: "no-backup",
                text: String(localized: "Резервных копий базы нет"),
                isUrgent: false,
                action: String(localized: "Резервные копии"),
                go: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Резервные копии"))) }
            ))
        }
        return found
    }

    private var decisionsSection: some View {
        let items = decisions
        return Section {
            if items.isEmpty {
                Text("Всё в порядке")
            } else {
                ForEach(items) { item in
                    LabeledContent {
                        if let action = item.action, let go = item.go {
                            Button(action, action: go)
                                .buttonStyle(.link)
                        }
                    } label: {
                        StatusLabel(item.isUrgent ? .warning : .off, item.text)
                    }
                }
            }
        } header: {
            Text("Требует решения")
        } footer: {
            if items.isEmpty {
                Text("Приложение подключено, файлы прочитаны, доступ настроен.")
            }
        }
    }
}
