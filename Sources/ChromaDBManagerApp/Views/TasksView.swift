import SwiftUI
import ChromaCore

/// «Задачи»: what is running, what is waiting, and the two controls that
/// belong to a queue — pause and cancel.
///
/// Before this screen the app could be busy for an hour with nothing to point
/// at; the panel exists so «чем занято приложение» has an answer.
///
/// Тип Б: таблица задач — выполняемые первыми; «Пауза / Продолжить» и
/// «Отменить задачу» — тулбар и контекстное меню; пусто —
/// `ContentUnavailableView`. Оставшееся с прошлого запуска — строками над
/// таблицей: это решение, которого ждут от человека.
struct TasksView: View {
    @EnvironmentObject private var app: AppEnvironment
    /// Очередь — отдельным объектом: этот экран про неё и есть,
    /// а остальные не должны перерисовываться от её тиков (см. `QueueMirror`).
    @EnvironmentObject private var queueMirror: QueueMirror
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var sources: SourcesViewModel

    @State private var isPaused = false
    @State private var selection: QueuedTaskInfo.ID?
    /// Порядок, ширины и видимость колонок — помнит окно (v3).
    @SceneStorage("table.tasks.v3") private var columns: TableColumnCustomization<QueuedTaskInfo>

    /// Выполняемые — первыми: ради них экран и открывают.
    private var tasks: [QueuedTaskInfo] {
        queueMirror.tasks.filter { $0.state == .running } + queueMirror.tasks.filter { $0.state == .queued }
    }

    private var queuedCount: Int { queueMirror.tasks.filter { $0.state == .queued }.count }

    var body: some View {
        VStack(spacing: 0) {
            topRows
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Нет задач"), systemImage: "checklist")
                } description: {
                    Text(isPaused
                         ? String(localized: "Очередь на паузе: ничего не запускается, пока её не продолжить.")
                         : String(localized: "Сейчас ничего не выполняется и ничего не ждёт."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            footer
        }
        .toolbar { toolbarContent }
        .task { isPaused = await app.queue.paused }
    }

    // MARK: - Над таблицей

    /// Пауза и то, что осталось с прошлого запуска, — строками над таблицей.
    @ViewBuilder
    private var topRows: some View {
        if isPaused || !queueMirror.resumableRequests.isEmpty {
            VStack(alignment: .leading) {
                if isPaused {
                    HStack {
                        Notice(.warning, String(localized: "Очередь на паузе: новые задачи не запускаются, уже начатая доигрывает до конца."))
                        Spacer()
                        Button(String(localized: "Продолжить")) { setPaused(false) }
                    }
                }
                // Приложение не запускает их само: индексация меняет базу,
                // а молча база не меняется.
                ForEach(queueMirror.resumableRequests, id: \.self) { request in
                    HStack {
                        Notice(.info, String(localized: "Осталось с прошлого запуска: \(request.title) — \(Self.kindTitle(request.kind))"))
                        Spacer()
                        if request.kind == .sync,
                           let id = UUID(uuidString: request.subject),
                           let source = settings.configuration.dataSources.first(where: { $0.id == id }) {
                            Button(String(localized: "Продолжить")) {
                                app.forgetResumable(request)
                                Task { await sources.run(source, app: app, reason: .manual) }
                            }
                        }
                        Button(String(localized: "Забыть")) { app.forgetResumable(request) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding()
            Divider()
        }
    }

    // MARK: - Таблица

    private var table: some View {
        // Строки однострочные (v3): подробности — своей колонкой.
        Table(tasks, selection: $selection, columnCustomization: $columns) {
            TableColumn(String(localized: "Задача")) { task in
                Text(task.title).lineLimit(1).help(task.title)
            }
            .customizationID("tasks.задача")
            TableColumn(String(localized: "Подробности")) { task in
                Text(task.detail ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.detail ?? "")
            }
            .customizationID("tasks.подробности")
            TableColumn(String(localized: "Ход")) { task in
                if task.state == .running {
                    if let progress = task.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Text("ждёт \(Int(task.waitedSeconds).plainDigits) с")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 160, max: 220)
            .customizationID("tasks.ход")
            TableColumn(String(localized: "Состояние")) { task in
                if task.state == .running {
                    StatusLabel(.ok, task.startedAt.map {
                        String(localized: "выполняется с \(Self.time.string(from: $0))")
                    } ?? String(localized: "выполняется"))
                } else {
                    StatusLabel(.off, String(localized: "в очереди"))
                }
            }
            .width(min: 120, ideal: 170, max: 240)
            .customizationID("tasks.состояние")
            TableColumn(String(localized: "Приоритет")) { task in
                Text(task.priority.title).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140, max: 200)
            .customizationID("tasks.приоритет")
            TableColumn(String(localized: "Группа")) { task in
                Text(task.group.title).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 140, max: 200)
            .customizationID("tasks.группа")
        }
        .contextMenu(forSelectionType: QueuedTaskInfo.ID.self) { ids in
            Button(String(localized: "Отменить задачу"), role: .destructive) {
                for id in ids { app.cancelTask(id) }
            }
            .disabled(ids.isEmpty)
        }
        .onDeleteCommand {
            if let selection { app.cancelTask(selection) }
        }
    }

    private var footer: some View {
        TableFooter(
            footerLine,
            help: String(localized: "Порядок очереди: действие пользователя, запрос агента, ручная операция, автоматическая, фоновая проверка. Внутри одного приоритета — в порядке поступления. Задачи, которым нужна одна и та же локальная модель, идут по очереди. Долгая задача не прерывается на полпути: она уступает очередь между батчами эмбеддинга — поэтому поиск во время индексации папки ждёт не всю папку, а текущий батч. Пауза останавливает запуск новых задач; уже начатая доигрывает до конца. Задачи закрывшегося подключения снимаются.")
        )
    }

    private var footerLine: String {
        let running = tasks.count - queuedCount
        return String(localized: "Выполняется: \(running.plainDigits) · в очереди: \(queuedCount.plainDigits)")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let selection { app.cancelTask(selection) }
            } label: {
                Label(String(localized: "Отменить задачу"), systemImage: "xmark.circle")
            }
            .help(String(localized: "Отменить выбранную задачу"))
            .disabled(selection == nil)
            // Надпись и значок меняются по состоянию: видно, что очередь
            // сейчас на паузе, а не только что нажать.
            Button {
                setPaused(!isPaused)
            } label: {
                Label(isPaused ? String(localized: "Продолжить") : String(localized: "Пауза"),
                      systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .help(isPaused
                  ? String(localized: "Продолжить очередь")
                  : String(localized: "Приостановить запуск новых задач"))
        }
    }

    /// The same pause the «Источники» screen shows: one state, two places to
    /// reach it. Через координатор — он ставит на паузу очередь и
    /// перестраивает таймеры и слежение.
    private func setPaused(_ paused: Bool) {
        isPaused = paused
        app.autoSync.setPaused(paused, app: app)
    }

    private static func kindTitle(_ kind: ResumableRequest.Kind) -> String {
        switch kind {
        case .sync: return String(localized: "синхронизация источника")
        case .importDocuments: return String(localized: "импорт документов")
        case .reembedding: return String(localized: "пересчёт векторов")
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
