import SwiftUI
import ChromaCore

/// «Задачи»: what is running, what is waiting, and the two controls that
/// belong to a queue — pause and cancel.
///
/// Before this screen the app could be busy for an hour with nothing to point
/// at; the panel exists so «чем занято приложение» has an answer.
struct TasksView: View {
    @EnvironmentObject private var app: AppEnvironment
    /// Очередь — отдельным объектом: этот экран про неё и есть,
    /// а остальные не должны перерисовываться от её тиков (см. `QueueMirror`).
    @EnvironmentObject private var queueMirror: QueueMirror
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var sources: SourcesViewModel

    @State private var isPaused = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if !queueMirror.resumableRequests.isEmpty { resumableCard }
                runningCard
                if !queued.isEmpty { queuedCard }
                explanation
            }
            .padding(.top, 4)
            .pageContentPadding()
        }
        .task { isPaused = await app.queue.paused }
    }

    private var running: [QueuedTaskInfo] { queueMirror.tasks.filter { $0.state == .running } }
    private var queued: [QueuedTaskInfo] { queueMirror.tasks.filter { $0.state == .queued } }

    /// Пауза очереди — рядом с тем, что она останавливает.
    ///
    /// Стояла кнопкой в шапке экрана, где читалась как действие раздела;
    /// на деле это переключатель состояния очереди, и место ему в её карточке.
    private var pauseButton: some View {
        Button(isPaused
               ? String(localized: "Продолжить")
               : String(localized: "Пауза")) {
            let next = !isPaused
            isPaused = next
            app.setQueuePaused(next)
            // The same pause the «Источники» screen shows: one state, two
            // places to reach it.
            settings.configuration.automaticSyncPaused = next
        }
        .buttonStyle(isPaused ? .chromaPrimary : .chromaNormal)
    }

    // MARK: - Running

    private var runningCard: some View {
        SectionCard(
            title: String(localized: "Выполняется"),
            subtitle: String(localized: "Задачи, которым нужна одна и та же локальная модель, идут по очереди — одновременно она обслуживает одну.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                if running.isEmpty {
                    Text(isPaused
                         ? String(localized: "Очередь на паузе: ничего не запускается, пока её не продолжить.")
                         : String(localized: "Сейчас ничего не выполняется."))
                        .font(Theme.Font.body)
                        .foregroundStyle(isPaused ? Theme.Palette.attention : Theme.Palette.captionText)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(running) { task in
                            taskRow(task, isRunning: true)
                            if task.id != running.last?.id { Divider() }
                        }
                    }
                }
                HStack {
                    pauseButton
                    Spacer()
                    if !queued.isEmpty {
                        Text("в очереди \(RussianCount.grouped(queued.count, "задача", "задачи", "задач"))")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                }
            }
        }
    }

    private var queuedCard: some View {
        SectionCard(
            title: String(localized: "В очереди"),
            subtitle: String(localized: "Порядок: действие пользователя, запрос агента, ручная операция, автоматическая, фоновая проверка. Внутри одного приоритета — в порядке поступления.")
        ) {
            if queued.isEmpty {
                Text(String(localized: "Очередь пуста."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(queued) { task in
                        taskRow(task, isRunning: false)
                        if task.id != queued.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: QueuedTaskInfo, isRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title).font(Theme.Font.body)
                Spacer()
                Button(String(localized: "Отменить")) { app.cancelTask(task.id) }
                    .buttonStyle(.chromaSecondary)
            }

            if isRunning, let progress = task.progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 420)
            }

            Text(subtitle(for: task, isRunning: isRunning))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .lineLimit(2)
        }
    }

    private func subtitle(for task: QueuedTaskInfo, isRunning: Bool) -> String {
        var parts = [task.priority.title, task.group.title]
        if isRunning, let started = task.startedAt {
            parts.append(String(localized: "начата в \(Self.time.string(from: started))"))
        } else {
            parts.append(String(localized: "ждёт \(Int(task.waitedSeconds).plainDigits) с"))
        }
        if let detail = task.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Left over from last time

    private var resumableCard: some View {
        SectionCard(
            title: String(localized: "Осталось с прошлого запуска"),
            subtitle: String(localized: "Приложение не запускает их само: индексация меняет базу, а молча база не меняется.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(queueMirror.resumableRequests, id: \.self) { request in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.title).font(Theme.Font.body)
                            Text(Self.kindTitle(request.kind))
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        }
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
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private static func kindTitle(_ kind: ResumableRequest.Kind) -> String {
        switch kind {
        case .sync: return String(localized: "синхронизация источника")
        case .importDocuments: return String(localized: "импорт документов")
        case .reembedding: return String(localized: "пересчёт векторов")
        }
    }

    /// Третий уровень текста — свёрнуто: читают один раз (правило 8).
    private var explanation: some View {
        HowItWorks(screen: "tasks") {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Порядок очереди: действие пользователя, запрос агента, ручная операция, автоматическая, фоновая проверка. Внутри одного приоритета — в порядке поступления."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "Долгая задача не прерывается на полпути: прерывание оставило бы наполовину записанный файл. Вместо этого она уступает очередь между батчами эмбеддинга — поэтому ваш поиск во время индексации папки ждёт не всю папку, а текущий батч."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "Пауза останавливает запуск новых задач; уже начатая доигрывает до конца. Задачи закрывшегося подключения снимаются: они работают с базой, которой больше нет."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
