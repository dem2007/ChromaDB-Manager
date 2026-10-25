import SwiftUI
import ChromaCore

/// Содержимое значка в строке меню.
///
/// Окном, а не обычным меню: в обычное меню нельзя положить поле ввода,
/// а быстрый поиск без поля ввода — это не быстрый поиск.
struct MenuBarView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var queueMirror: QueueMirror
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var search: QuickSearchViewModel
    /// Состояние моста для агентов. Наблюдается напрямую: `AppEnvironment`
    /// о его изменениях не рассказывает.
    @ObservedObject var mcp: MCPService
    /// Открыть главное окно и, если надо, окно просмотра.
    let openMainWindow: (ExternalRequest?) -> Void
    let openViewerWindow: () -> Void

    private var summary: MenuBarSummary {
        MenuBarSummary(
            tasks: queueMirror.tasks,
            paused: settings.configuration.automaticSyncPaused,
            lastSync: app.lastSyncSummary
        )
    }

    var body: some View {
        VStack(alignment: .leading) {
            // Сначала — состояние: сервер и задачи, затем MCP (v6); что
            // делается и пауза — под ними.
            serverLine
            mcpStatus
            Divider()
            status
            Divider()
            quickSearch
            Divider()
            footer
        }
        .menuBarPanel()
    }

    // MARK: - Состояние

    /// Сервер — состоянием подключения; справа — сколько задач.
    private var serverLine: some View {
        HStack {
            StatusLabel(serverState.0, serverState.1)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(queueMirror.tasks.isEmpty
                 ? String(localized: "задач нет")
                 : String(localized: "задач: \(queueMirror.tasks.count.plainDigits)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serverState: (StatusLabel.State, String) {
        switch app.connection {
        case .connected(_, _, let isLocal, _):
            return (.ok, isLocal ? String(localized: "Сервер работает") : String(localized: "Подключено к серверу"))
        case .connecting:
            return (.warning, String(localized: "Подключение…"))
        case .failed:
            return (.error, String(localized: "Нет подключения к базе"))
        // Не «сервер остановлен»: у внешнего сервера или при живом процессе
        // без подключения это неправда — разорвано подключение.
        case .disconnected:
            return (.off, String(localized: "Не подключено"))
        }
    }

    private var status: some View {
        VStack(alignment: .leading) {
            // Что идёт сейчас — только когда идёт: «Задач нет» — уже в первой
            // строке счётчиком.
            if summary.isBusy || summary.paused {
                Label(summary.headline, systemImage: summary.symbol)
                    .font(.callout)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let queue = summary.queueLine {
                Text(queue).font(.caption).foregroundStyle(.secondary)
            }
            if let paused = summary.pausedLine {
                Notice(.warning, paused).font(.caption)
            }
            if let sync = summary.lastSync {
                Text(sync).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            // Глобальная пауза (8.4) — прямо здесь: ради неё в строку меню
            // и заглядывают, когда LM Studio занята чем-то другим.
            //
            // Через координатор, а не записью флага: пауза — это ещё и пауза
            // очереди, и таймеры со слежением.
            Toggle(isOn: Binding(
                get: { settings.configuration.automaticSyncPaused },
                set: { app.autoSync.setPaused($0, app: app) }
            )) {
                Text("Пауза автоматической синхронизации").font(.caption)
            }
            .toggleStyle(.switch).controlSize(.mini)
        }
    }

    // MARK: - MCP

    /// Работает ли мост для агентов — прямо здесь, в строке меню.
    ///
    /// Ради этого вопроса окно и оставляют закрытым: «приложение можно
    /// закрыть, но агент должен ходить».
    private var mcpStatus: some View {
        HStack {
            StatusLabel(
                mcp.isListening ? .ok : (mcp.lastError == nil ? .off : .error),
                mcp.isListening
                    ? String(localized: "MCP слушает")
                    : String(localized: "MCP не запущен")
            )
            .font(.caption)
            if mcp.isListening {
                // Сколько мостов открыто сейчас и сколько вызовов было за
                // сеанс: «слушает» и «им пользуются» — разные факты.
                Text(mcp.connections.isEmpty
                     ? String(localized: "подключений нет")
                     : String(localized: "подключений: \(mcp.connections.count.plainDigits)"))
                    .font(.caption).foregroundStyle(.secondary)
                if mcp.callCount > 0 {
                    // Разделитель — отдельным видом: склеенный интерполяцией,
                    // он уезжал в каталог текстов ключом «· %@».
                    Text(verbatim: "·").font(.caption).foregroundStyle(.secondary)
                    Text("вызовов: \(mcp.callCount.plainDigits)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = mcp.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(error)
            }
            Spacer()
        }
    }

    // MARK: - Быстрый поиск

    private var quickSearch: some View {
        // Тот же вид, что в панели по горячей клавише: две реализации
        // быстрого поиска разошлись бы через месяц.
        QuickSearchView(search: search, openDocument: openViewerWindow, fillsHeight: false)
    }

    // MARK: - Низ

    private var footer: some View {
        HStack {
            Button(String(localized: "Открыть окно")) {
                openMainWindow(search.hits.isEmpty ? nil : .search(
                    collection: settings.configuration.menuBar.quickSearchCollection,
                    text: search.text
                ))
            }
            .controlSize(.small)
            Spacer()
            Button(String(localized: "Выйти")) { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}
