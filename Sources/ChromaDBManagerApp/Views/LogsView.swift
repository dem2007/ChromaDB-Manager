import SwiftUI
import AppKit
import ChromaCore

/// «Логи»: события приложения, журнал доступа, вывод сервера.
///
/// «События» и «Сервер» — `LogView` на всю деталь, фильтры и действия — в
/// тулбаре. «Доступ» — тип Б: таблица по дням. Сроки хранения журналов —
/// в окне «Настройки» → «Хранение».
struct LogsView: View {
    /// Почему запрос отклонён — или `nil`, если прошёл.
    private static func refusal(of entry: AuditEntry) -> String? {
        if let note = entry.note { return note }
        if let status = entry.responseStatus, status >= 400 {
            return String(localized: "Отказ: код \(status.plainDigits)")
        }
        return nil
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var audit: AuditLog
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var reembedding: ReembeddingViewModel
    /// Модель сервера — ради его собственного журнала: вывод процесса читают
    /// там же, где остальные журналы, а не в разделе управления.
    @ObservedObject var serverModel: ServerViewModel
    /// Разрез: «События», «Доступ», «Сервер».
    var tab: Int = 0
    /// Поиск журнала доступа — снаружи: «Клиенты → Показать в журнале»
    /// приходит сюда с именем клиента.
    @Binding var auditSearch: String

    @State private var level: LogEntry.Level?
    @State private var category: String?
    @State private var searchText = ""
    @State private var followsEnd = true
    @State private var confirmingClear = false
    @State private var showsJournal = false
    @State private var showsArchives = false
    /// Отбор «только запись» — выключен: агент почти всегда читает,
    /// и включённый с начала отбор выглядел как «журнал не пишется».
    @State private var auditWritesOnly = false
    @State private var auditCollection: String?
    @State private var auditSelection: Set<AuditEntry.ID> = []
    /// Порядок, ширины и видимость колонок журнала — помнит окно (v3).
    @SceneStorage("table.audit.v3") private var auditColumns: TableColumnCustomization<AuditEntry>
    @State private var showArchiveConfirmation = false

    var body: some View {
        Group {
            switch tab {
            case 1:
                accessTab
            case 2:
                ServerOutputTab(serverModel: serverModel)
            default:
                eventsTab
            }
        }
        .task { serverModel.refreshRuns(app) }
        .sheet(isPresented: $showsJournal) {
            ReembeddingJournalSheet(reembedding: reembedding) { showsJournal = false }
        }
        .sheet(isPresented: $showsArchives) {
            AuditArchivesSheet { showsArchives = false }
        }
    }

    // MARK: - События

    private var entries: [LogEntry] {
        app.log.entries.filter { entry in
            (level == nil || entry.level == level)
                && (category == nil || entry.category == category)
                && (searchText.isEmpty
                    || entry.message.localizedCaseInsensitiveContains(searchText)
                    || entry.category.localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Строки журнала с границей дня: в строке одно время, и
    /// «22:48:44» само не говорит, сегодня это или на прошлой неделе.
    /// Граница — сравнением с предыдущей записью, без словаря дней: буфер
    /// держит тысячи строк и переиздаётся на каждую новую.
    private var eventLines: [String] {
        let shown = entries
        var lines: [String] = []
        lines.reserveCapacity(shown.count + 8)
        for (position, entry) in shown.enumerated() {
            if position == 0 || !Calendar.current.isDate(entry.date, inSameDayAs: shown[position - 1].date) {
                lines.append("── \(Self.dayTitle(entry.date)) ──")
            }
            lines.append(entry.formatted)
        }
        return lines
    }

    private var eventsTab: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Записей нет"), systemImage: "list.bullet.rectangle")
                } description: {
                    Text(app.log.entries.isEmpty
                         ? String(localized: "Здесь появится то, что приложение делает прямо сейчас.")
                         : String(localized: "Под отбор ничего не подходит."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogView(lines: eventLines, followsEnd: followsEnd)
            }
            TableFooter(
                String(localized: "Записи дублируются в файл; токены и ключи маскируются до записи."),
                help: String(localized: "Файл на диске переживает перезапуск приложения, окно «Событий» — нет: на экране показаны записи текущей сессии. Сколько журналов держать на диске — «Настройки» → «Хранение».")
            )
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Поиск"))
        .toolbar { eventsToolbar }
        .confirmationDialog(
            String(localized: "Очистить журнал событий на экране?"),
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Очистить"), role: .destructive) { app.log.clear() }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text("Записи текущей сессии уйдут с экрана. Файл журнала на диске останется как есть.")
        }
    }

    @ToolbarContentBuilder
    private var eventsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(String(localized: "Источник"), selection: $category) {
                Text(String(localized: "Все источники")).tag(String?.none)
                ForEach(app.log.categories, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .help(String(localized: "Показать события одного источника"))
            Picker(String(localized: "Уровень"), selection: $level) {
                Text(String(localized: "Все уровни")).tag(LogEntry.Level?.none)
                ForEach(LogEntry.Level.allCases, id: \.self) { item in
                    Text(item.title).tag(LogEntry.Level?.some(item))
                }
            }
            .help(String(localized: "Показать события одного уровня"))
            Toggle(isOn: $followsEnd) {
                Label(String(localized: "Следить за концом"), systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help(String(localized: "Прокручивать к новой записи"))
            Menu {
                Button(String(localized: "Скопировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(eventsText, forType: .string)
                }
                .disabled(entries.isEmpty)
                // Журнал событий сохраняется в файл, как и журнал доступа:
                // приложить журнал к письму из буфера нельзя.
                Button(String(localized: "Сохранить…")) { saveEvents() }
                    .disabled(entries.isEmpty)
                Divider()
                Button(String(localized: "Журнал пересчётов…")) {
                    reembedding.refreshJournal(app)
                    showsJournal = true
                }
                Button(String(localized: "Показать файл журнала в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        app.log.logFileURL ?? AppPaths.logsDirectory
                    ])
                }
            } label: {
                Label(String(localized: "Экспорт"), systemImage: "square.and.arrow.up")
            }
            .help(String(localized: "Скопировать, сохранить, журнал пересчётов"))
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label(String(localized: "Очистить…"), systemImage: "trash")
            }
            .help(String(localized: "Очистить журнал событий на экране"))
            .disabled(app.log.entries.isEmpty)
        }
    }

    /// Журнал событий текстом — ровно в том отборе, что виден на экране.
    private var eventsText: String {
        app.log.exportText(level: level, category: category, search: searchText)
    }

    private func saveEvents() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "chromadb-events-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try eventsText.write(to: url, atomically: true, encoding: .utf8)
            app.log.record(.success, "Логи", "Журнал событий сохранён: \(url.path)")
        } catch {
            app.report(error, category: "Логи")
        }
    }

    // MARK: - Доступ

    /// Access log of everything that went through the proxy.
    private var accessTab: some View {
        let rows = audit.filtered(writesOnly: auditWritesOnly, collection: auditCollection, search: auditSearch)
        let days = Self.byDay(rows, date: \.date)
        return VStack(spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Записей нет"), systemImage: "person.badge.shield.checkmark")
                } description: {
                    Text(audit.entries.isEmpty
                         ? String(localized: "Через прокси и MCP ещё никто не обращался.")
                         : String(localized: "Под отбор ничего не подходит."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Строки однострочные (v3): операция и её тип — двумя
                // колонками, а не двумя строками в одной ячейке.
                Table(of: AuditEntry.self, selection: $auditSelection, columnCustomization: $auditColumns) {
                    TableColumn(String(localized: "Время")) { entry in
                        Text(Self.time.string(from: entry.date)).monospacedDigit()
                    }
                    .width(min: 60, ideal: 80, max: 110)
                    .customizationID("time")
                    TableColumn(String(localized: "Клиент")) { entry in
                        Text(entry.client).lineLimit(1).help(entry.client)
                    }
                    .width(min: 80, ideal: 120, max: 170)
                    .customizationID("client")
                    TableColumn(String(localized: "Канал")) { entry in
                        Text(entry.transport.title).foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 70, max: 80)
                    .customizationID("transport")
                    TableColumn(String(localized: "Операция")) { entry in
                        // Отказ — красным прямо в операции: колонка «Итог»
                        // по умолчанию скрыта (v4 A6), а отказ прятаться не
                        // должен.
                        Group {
                            if let refusal = Self.refusal(of: entry) {
                                StatusLabel(.error, entry.title).help(refusal)
                            } else {
                                Text(entry.title)
                                    // Полный текст параметров — по наведению.
                                    .help(entry.parameters ?? entry.title)
                            }
                        }
                        .lineLimit(1)
                    }
                    .customizationID("operation")
                    TableColumn(String(localized: "Тип")) { entry in
                        // Удаление и запись названы своим словом: их
                        // ищут глазами.
                        if entry.access.changesData {
                            StatusLabel(.warning, entry.access.title)
                        } else {
                            Text(entry.access.title).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 60, ideal: 70, max: 100)
                    .customizationID("access")
                    TableColumn(String(localized: "Коллекция")) { entry in
                        Text(entry.collection ?? "—")
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(entry.collection ?? "")
                    }
                    .width(min: 80, ideal: 140, max: 200)
                    .customizationID("collection")
                    // Отказ — кодом у прокси и причиной у MCP (`note`): у MCP
                    // кода нет, и без причины отказ выглядел бы успехом.
                    TableColumn(String(localized: "Итог")) { entry in
                        if let note = entry.note {
                            StatusLabel(.error, note)
                                .lineLimit(1)
                                .help(note)
                        } else if let status = entry.responseStatus {
                            if status >= 400 {
                                StatusLabel(.error, status.plainDigits)
                            } else {
                                Text(status.plainDigits).foregroundStyle(.secondary)
                            }
                        }
                        // Успех без кода (MCP) — пустая ячейка, а не «—»:
                        // колонка из одних прочерков прятала бы отказы (v3).
                    }
                    .width(min: 50, ideal: 110, max: 150)
                    .customizationID("result")
                    // У успешных строк колонка пуста; отказ виден в «Операции».
                    .defaultVisibility(.hidden)
                    TableColumn(String(localized: "Размер")) { entry in
                        Text(entry.sizeText).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 60, ideal: 80, max: 110)
                    .alignment(.numeric)
                    .customizationID("size")
                } rows: {
                    // По дням: в строке только время.
                    ForEach(days) { day in
                        Section {
                            ForEach(day.items) { entry in
                                SwiftUI.TableRow(entry)
                            }
                        } header: {
                            Text("\(day.title) · \(day.items.count.formatted())")
                        }
                    }
                }
                .contextMenu(forSelectionType: AuditEntry.ID.self) { ids in
                    let chosen = rows.filter { ids.contains($0.id) }
                    Button(String(localized: "Скопировать параметры")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(chosen.compactMap(\.parameters).joined(separator: "\n"), forType: .string)
                    }
                    .disabled(chosen.allSatisfy { $0.parameters == nil })
                    Button(String(localized: "Показать только этого клиента")) {
                        if let client = chosen.first?.client { auditSearch = client }
                    }
                    .disabled(chosen.count != 1)
                }
            }
            // Число отобранных — не число записей вовсе: иначе отбор читался
            // как пустой журнал.
            TableFooter(
                rows.count == audit.entries.count
                    ? String(localized: "Записей: \(rows.count.formatted())")
                    : String(localized: "Показано \(rows.count.formatted()) из \(audit.entries.count.formatted()) — остальное скрыто отбором"),
                help: String(localized: "Каждый запрос, прошедший через прокси или MCP: кто, к какой коллекции и чем закончилось. Пишет прокси, а не движок: обращения локальных программ напрямую к 127.0.0.1 сюда не попадают — их никто не видит. Ключи в записях маскируются.")
            )
        }
        .searchable(text: $auditSearch, placement: .toolbar, prompt: Text("Поиск"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker(String(localized: "Коллекция"), selection: $auditCollection) {
                    Text(String(localized: "Все коллекции")).tag(String?.none)
                    ForEach(audit.collections, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .help(String(localized: "Показать обращения к одной коллекции"))
                // Пунктом меню с галочкой, а не значком (v3): значок
                // «карандаш» читали как «новый журнал».
                Menu {
                    Toggle(String(localized: "Только запись и удаление"), isOn: $auditWritesOnly)
                    Divider()
                    Button(String(localized: "Экспортировать в CSV…")) { exportAudit(rows, asJSON: false) }
                        .disabled(rows.isEmpty)
                    Button(String(localized: "Экспортировать в JSON…")) { exportAudit(rows, asJSON: true) }
                        .disabled(rows.isEmpty)
                    Divider()
                    Button(String(localized: "Архивы…")) { showsArchives = true }
                    // Не «Очистить»: журнал доступа, который сам себя стирает,
                    // бесполезен — файл уезжает в архив.
                    Button(String(localized: "Начать новый журнал…")) { showArchiveConfirmation = true }
                        .disabled(audit.entries.isEmpty)
                } label: {
                    Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            String(localized: "Начать новый журнал доступа?"),
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Начать новый")) { audit.archiveCurrent() }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text("Записей сейчас: \(audit.entries.count.formatted()). Они не удаляются — текущий файл уезжает в архив, его видно в «Ещё» → «Архивы…». Экран журнала при этом станет пустым.")
        }
    }

    private func exportAudit(_ rows: [AuditEntry], asJSON: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = asJSON ? "chromadb-audit.json" : "chromadb-audit.csv"
        panel.allowedContentTypes = [asJSON ? .json : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = asJSON ? app.audit.exportJSON(rows) : app.audit.exportCSV(rows)
            try text.write(to: url, atomically: true, encoding: .utf8)
            app.log.record(.success, "Аудит", "Журнал доступа выгружен в \(url.lastPathComponent)")
        } catch {
            app.report(error, category: "Аудит")
        }
    }

    // MARK: - По дням

    /// Записи одного дня — с подписью, которую можно прочесть вслух.
    struct DayGroup<Item: Identifiable>: Identifiable {
        let id: Date
        let title: String
        let items: [Item]
    }

    /// Разбивает журнал по дням, сохраняя порядок записей.
    static func byDay<Item: Identifiable>(
        _ items: [Item], date: (Item) -> Date
    ) -> [DayGroup<Item>] {
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [Item]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(item)
        }
        return order.map { day in
            DayGroup(id: day, title: dayTitle(day, calendar: calendar), items: grouped[day] ?? [])
        }
    }

    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "сегодня") }
        if calendar.isDateInYesterday(day) { return String(localized: "вчера") }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        return day.formatted(
            sameYear ? Date.FormatStyle().day().month(.wide)
                     : Date.FormatStyle().day().month(.wide).year()
        )
    }
}

// MARK: - Вывод сервера

/// «Вывод сервера» — отдельным видом, со своим наблюдением за процессом.
///
/// Экран журнала наблюдал `ChromaProcessManager` целиком, а тот каждую
/// секунду публикует время работы сервера: весь журнал перерисовывался раз
/// в секунду ради этой вкладки. Теперь перерисовывается она одна.
private struct ServerOutputTab: View {
    @EnvironmentObject private var processManager: ChromaProcessManager
    @ObservedObject var serverModel: ServerViewModel

    var body: some View {
        let lines = serverModel.visibleLines(processManager.recentOutput)
        VStack(spacing: 0) {
            if processManager.recentOutput.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Вывода пока нет"), systemImage: "terminal")
                } description: {
                    Text("Сервер ещё не запускался в этой сессии.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView.search(text: serverModel.filter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogView(lines: lines, followsEnd: serverModel.followsTail)
            }
            // Verified on chroma 1.4.4: the server prints its banner and then
            // goes quiet — better to say so than to let an empty panel look
            // like a defect.
            TableFooter(
                String(localized: "То, что процесс chroma печатает сам."),
                help: String(localized: "ChromaDB печатает только приветствие при запуске и сообщение об ошибке, если падает; отдельных записей по каждому запросу у неё нет. Вывод сохраняется в файл — последние 5 запусков доступны в меню «Файлы».")
            )
        }
        .searchable(text: $serverModel.filter, placement: .toolbar, prompt: Text("Фильтр"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $serverModel.followsTail) {
                    Label(String(localized: "Следить за концом"), systemImage: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help(String(localized: "Прокручивать к новой строке"))
                Button {
                    serverModel.copyLog(processManager.recentOutput)
                } label: {
                    Label(String(localized: "Скопировать"), systemImage: "doc.on.doc")
                }
                .help(String(localized: "Скопировать вывод сервера"))
                .disabled(processManager.recentOutput.isEmpty)
                Menu {
                    if serverModel.pastRuns.isEmpty {
                        Text(String(localized: "Пока нет записей"))
                    }
                    ForEach(serverModel.pastRuns) { run in
                        Button("\(run.startedAt.formatted(date: .abbreviated, time: .standard)) · \(run.sizeText)") {
                            serverModel.revealRun(run)
                        }
                    }
                } label: {
                    Label(String(localized: "Файлы"), systemImage: "folder")
                }
                .help(String(localized: "Файлы вывода прошлых запусков — показать в Finder"))
            }
        }
    }
}

// MARK: - Журнал пересчётов

/// История пересчётов векторов — листом из «Экспорт → Журнал
/// пересчётов…». Живёт в файле, а не в журнале событий, поэтому переживает
/// перезапуск и «Очистить».
private struct ReembeddingJournalSheet: View {
    @ObservedObject var reembedding: ReembeddingViewModel
    let close: () -> Void

    var body: some View {
        SheetFrame(width: .wide, height: .tall) {
            Section {
                if reembedding.journal.isEmpty {
                    Text("Пересчётов ещё не было.").foregroundStyle(.secondary)
                } else {
                    ForEach(reembedding.journal) { entry in
                        VStack(alignment: .leading) {
                            HStack {
                                StatusLabel(state(entry.outcome), entry.outcome.title)
                                Spacer()
                                Text(entry.finishedAt.formatted(date: .abbreviated, time: .standard))
                                    .foregroundStyle(.secondary)
                            }
                            Text("«\(entry.sourceCollection)» → «\(entry.resultCollection)» · \(entry.scenario.title)")
                            Text("\(entry.model)\(entry.dimension > 0 ? " · размерность \(entry.dimension)" : "") · обработано \(entry.processed), записано \(entry.written)")
                                .foregroundStyle(.secondary)
                            if !entry.detail.isEmpty {
                                Text(entry.detail).foregroundStyle(.secondary)
                            }
                        }
                        .copyable([entry.sourceCollection, entry.resultCollection, entry.model, entry.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                }
            } header: {
                SectionHeader(
                    String(localized: "Журнал пересчётов"),
                    help: String(localized: "История операций re-embedding: что, когда, какой моделью и с каким исходом. Живёт в файле, поэтому переживает перезапуск приложения и очистку журнала событий.")
                )
            }
        } actions: {
            Spacer()
            Button(String(localized: "Закрыть"), action: close)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func state(_ outcome: ReembeddingJournalEntry.Outcome) -> StatusLabel.State {
        switch outcome {
        case .finished: return .ok
        case .cancelled: return .warning
        case .failed: return .error
        }
    }
}

// MARK: - Архивы журнала доступа

/// Архивы журнала доступа: видны, открываются в Finder, удаляются только
/// с подтверждением.
private struct AuditArchivesSheet: View {
    @EnvironmentObject private var audit: AuditLog
    let close: () -> Void
    @State private var archiveToDelete: AuditArchive?

    var body: some View {
        let archives = audit.archives()
        SheetFrame(width: .wide) {
            Section {
                if archives.isEmpty {
                    Text("Архивов нет: журнал доступа ещё ни разу не начинали заново.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(archives) { archive in
                        LabeledContent {
                            Text(archive.sizeText).foregroundStyle(.secondary)
                        } label: {
                            Text(archive.url.lastPathComponent)
                                .font(.body.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .contextMenu {
                            Button(String(localized: "Показать в Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([archive.url])
                            }
                            Divider()
                            Button(String(localized: "Удалить…"), role: .destructive) {
                                archiveToDelete = archive
                            }
                        }
                    }
                }
            } header: {
                Text("Архивы журнала доступа")
            } footer: {
                Text("Архивы не удаляются сами: журнал доступа, который стирает себя, бесполезен. «Показать в Finder» и «Удалить…» — в контекстном меню архива.")
            }
        } actions: {
            Spacer()
            Button(String(localized: "Закрыть"), action: close)
                .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog(
            String(localized: "Удалить архив журнала доступа?"),
            isPresented: Binding(get: { archiveToDelete != nil }, set: { if !$0 { archiveToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить"), role: .destructive) {
                if let archiveToDelete { audit.removeArchive(archiveToDelete) }
                archiveToDelete = nil
            }
            Button(String(localized: "Отменить"), role: .cancel) { archiveToDelete = nil }
        } message: {
            Text(String(localized: "\(archiveToDelete?.url.lastPathComponent ?? "") будет удалён безвозвратно."))
        }
    }
}
