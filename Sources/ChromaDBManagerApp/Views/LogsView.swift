import SwiftUI
import AppKit
import ChromaCore

struct LogsView: View {
    /// Same clock format the file uses, kept here so the view can colour the
    /// timestamp separately from the message.
    private static func markerColour(_ level: LogEntry.Level) -> Color {
        switch level {
        case .success: return Theme.Palette.logSuccess
        case .warning: return Theme.Palette.attention
        case .error: return Theme.Palette.danger
        case .info, .debug: return Theme.Palette.logTimestamp
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var audit: AuditLog
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var processManager: ChromaProcessManager
    @ObservedObject var reembedding: ReembeddingViewModel
    /// Модель сервера — ради его собственного журнала, который переехал сюда
    /// с вкладки «Сервер»: вывод процесса читают там же, где остальные
    /// журналы, а не в разделе управления процессом.
    @ObservedObject var serverModel: ServerViewModel
    /// Разрез: «События», «Доступ», «Хранение», «Сервер».
    var tab: Int = 0
    @State private var level: LogEntry.Level?
    @State private var category: String?
    @State private var searchText = ""
    @State private var showJournal = false
    @State private var showAudit = false
    @State private var auditWritesOnly = true
    @State private var auditCollection: String?
    @State private var auditSearch = ""
    @State private var archiveToDelete: AuditArchive?
    @State private var showArchiveConfirmation = false

    private var entries: [LogEntry] {
        app.log.entries.filter { entry in
            (level == nil || entry.level == level)
                && (category == nil || entry.category == category)
                && (searchText.isEmpty
                    || entry.message.localizedCaseInsensitiveContains(searchText)
                    || entry.category.localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Access log of everything that went through the proxy.
    ///
    /// Writes only by default — that is what the spec asks to keep — but reads
    /// are recorded too and one checkbox away, because «did anything reach the
    /// database at all» is the first question a proxy raises.
    private var auditSection: some View {
        let rows = audit.filtered(writesOnly: auditWritesOnly, collection: auditCollection, search: auditSearch)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                SectionCard(
                    title: String(localized: "Журнал доступа"),
                    subtitle: String(localized: "Каждый запрос, прошедший через прокси или MCP: кто, к какой коллекции и чем закончилось. Записей: \(rows.count.formatted())."),
                    help: String(localized: "Пишет прокси, а не движок: обращения локальных программ напрямую к 127.0.0.1 сюда не попадают — их никто не видит. Ключи в записях маскируются.")
                ) {
                    VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                        auditControls(rows)

                        if rows.isEmpty {
                            Text(audit.entries.isEmpty
                                 ? String(localized: "Через прокси ещё никто не обращался.")
                                 : String(localized: "Под фильтр ничего не подходит."))
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.captionText)
                        } else {
                            // Лениво и без вложенной прокрутки: список внутри
                            // своего ScrollView не давал раскладке посчитать
                            // высоту, и содержимое окна разъезжалось вверх
                            // вместе с боковым меню.
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(rows.prefix(500)) { entry in
                                    auditRow(entry)
                                }
                            }
                            if rows.count > 500 {
                                Text("Показаны первые 500 записей из \(rows.count.formatted()). Полный журнал — в экспорте.")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.captionText)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .pageContentPadding()
        }
    }

    /// Фильтры журнала и то, что с ним делают.
    private func auditControls(_ rows: [AuditEntry]) -> some View {
        HStack(spacing: 10) {
            Toggle(String(localized: "Только запись"), isOn: $auditWritesOnly)
                .toggleStyle(.checkbox)
                .font(Theme.Font.control)
            Picker(String(localized: "Коллекция"), selection: $auditCollection) {
                Text(String(localized: "Все коллекции")).tag(String?.none)
                ForEach(audit.collections, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
            TextField(String(localized: "Поиск"), text: $auditSearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            Spacer(minLength: 0)
            Menu {
                Button(String(localized: "CSV…")) { exportAudit(rows, asJSON: false) }
                Button(String(localized: "JSON…")) { exportAudit(rows, asJSON: true) }
            } label: {
                Text(String(localized: "Экспорт"))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
            .disabled(rows.isEmpty)
            // Не «Очистить»: журнал доступа, который сам себя стирает,
            // бесполезен — файл уезжает в архив, и архивы остаются.
            // И не «Заархивировать»: под этим словом человек ждал копию, а
            // получал пустой экран — теперь кнопка называет своё следствие
            // и спрашивает подтверждение.
            Button(String(localized: "Начать новый журнал")) { showArchiveConfirmation = true }
                .buttonStyle(.chromaNormal)
                .disabled(audit.entries.isEmpty)
                .confirmationDialog(
                    String(localized: "Начать новый журнал доступа?"),
                    isPresented: $showArchiveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Начать новый")) { audit.archiveCurrent() }
                    Button(String(localized: "Отмена"), role: .cancel) {}
                } message: {
                    Text("Записей сейчас: \(audit.entries.count.formatted()). Они не удаляются — текущий файл уезжает в архив, и его видно на вкладке «Хранение». Экран журнала при этом станет пустым.")
                }
        }
    }

    private func auditRow(_ entry: AuditEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.access == .write ? String(localized: "запись") : String(localized: "чтение"))
                .font(Theme.Font.micro)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background((entry.access == .write
                             ? Theme.Palette.attention
                             : Theme.Palette.stopped).opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .font(Theme.Font.mono).foregroundStyle(Theme.Palette.captionText)
            Text(entry.client).font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.captionText)
            // Транспорт назван у записей MCP и не назван у прокси: пока он был
            // один, называть его было незачем, и строка прокси не должна
            // потолстеть оттого, что появился второй.
            if entry.transport == .mcp {
                Text(entry.transport.title)
                    .font(Theme.Font.micro)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.Palette.accent.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            }
            Text(entry.title).font(Theme.Font.caption)
                // Полный текст параметров — по наведению: в строке ему не
                // поместиться, а D2.5 требует, чтобы он был доступен.
                .help(entry.parameters ?? "")
            if let collection = entry.collection {
                Text(collection).font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let status = entry.responseStatus {
                Text(status.plainDigits)
                    .font(Theme.Font.caption)
                    .foregroundStyle(status >= 400
                                     ? Theme.Palette.danger
                                     : Theme.Palette.captionText)
            }
            Text(entry.sizeText).font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.captionText)
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
    }

    private func applyRetention() {
        app.log.apply(settings.configuration.logRetention)
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

    /// Archived audit files: visible, exportable by hand, and deletable only
    /// through a confirmation.
    @ViewBuilder
    private var auditArchivesSection: some View {
        let archives = audit.archives()
        if !archives.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Архивы журнала доступа").uppercased())
                    .font(Theme.Font.tableHeader)
                    .kerning(0.5)
                    .foregroundStyle(Theme.Palette.caption)
                ForEach(archives) { archive in
                    HStack(spacing: 8) {
                        Text(archive.url.lastPathComponent)
                            .font(Theme.Font.mono)
                            .lineLimit(1).truncationMode(.middle)
                        Text(archive.sizeText).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        Button(String(localized: "Показать в Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([archive.url])
                        }
                        .font(Theme.Font.micro)
                        Button(String(localized: "Удалить"), role: .destructive) {
                            archiveToDelete = archive
                        }
                        .font(Theme.Font.micro)
                        Spacer()
                    }
                }
                Text(String(localized: "Архивы не удаляются сами: журнал доступа, который стирает себя, бесполезен."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
            .padding(.horizontal, 16)
            .confirmationDialog(
                String(localized: "Удалить архив журнала доступа?"),
                isPresented: Binding(get: { archiveToDelete != nil }, set: { if !$0 { archiveToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Удалить"), role: .destructive) {
                    if let archiveToDelete { audit.removeArchive(archiveToDelete) }
                    archiveToDelete = nil
                }
                Button(String(localized: "Отмена"), role: .cancel) { archiveToDelete = nil }
            } message: {
                Text(String(localized: "\(archiveToDelete?.url.lastPathComponent ?? "") будет удалён безвозвратно."))
            }
        }
    }

    /// Re-embedding history, which the spec asks to keep in «Логи».
    /// It lives in a file rather than in the in-memory log, so it survives a
    /// restart and the «Очистить» button.
    private var journalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Журнал пересчётов").uppercased())
                .font(Theme.Font.tableHeader)
                .kerning(0.5)
                .foregroundStyle(Theme.Palette.caption)
            if reembedding.journal.isEmpty {
                Text(String(localized: "Пересчётов ещё не было."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            } else {
                ScrollView {
                    // Rows with a hairline between them, not a card per entry:
                    // a journal reads as one list.
                    TableCard {
                        ForEach(Array(reembedding.journal.enumerated()), id: \.element.id) { index, entry in
                            TableRow(isFirst: index == 0) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.outcome.title)
                                            .font(Theme.Font.micro)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(colour(for: entry.outcome).opacity(0.18))
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                                        Text(entry.finishedAt.formatted(date: .abbreviated, time: .standard))
                                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                        Text(entry.scenario.title).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                    }
                                    Text("«\(entry.sourceCollection)» → «\(entry.resultCollection)» · \(entry.model)\(entry.dimension > 0 ? " · размерность \(entry.dimension)" : "") · обработано \(entry.processed), записано \(entry.written)")
                                        .font(Theme.Font.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(entry.detail)
                                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.contentPadding)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colour(for outcome: ReembeddingJournalEntry.Outcome) -> Color {
        switch outcome {
        case .finished: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Панель фильтров — только у «Событий»: на соседних вкладках она
            // фильтровала не то, что на них показано.
            if tab == 0 { eventsToolbar }

            // Вкладка выбирает разрез журналов; кнопки «Журнал доступа» и
            // «Журнал пересчётов», которые надо было помнить включёнными,
            // больше не нужны.
            switch tab {
            case 1:
                auditSection
            case 2:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                        storageCard
                        auditArchivesSection
                    }
                    .padding(.top, 4)
                    .pageContentPadding()
                }
            case 3:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                        logCard
                    }
                    .padding(.top, 4)
                    .pageContentPadding()
                }
            default:
                eventsList
            }
        }
        .task { serverModel.refreshRuns(app) }
    }

    /// Поиск, фильтры и две кнопки над списком событий.
    private var eventsToolbar: some View {
        // Two rows: a single row of title + search + two pickers + buttons does
        // not fit next to the sidebar on a 13" screen.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "Что делает приложение прямо сейчас и что делало раньше."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                Spacer()
                Button(String(localized: "Копировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(eventsText, forType: .string)
                }
                .buttonStyle(.chromaNormal)
                // Журнал доступа умел сохраняться в файл, а журнал событий —
                // только в буфер обмена, хотя ядро отдаёт его текстом с той
                // же фильтрацией. Приложить журнал к письму из буфера нельзя
                //.
                Button(String(localized: "Сохранить…")) { saveEvents() }
                    .buttonStyle(.chromaNormal)
                    .disabled(entries.isEmpty)
                Button(String(localized: "Журнал пересчётов")) {
                    showJournal.toggle()
                    if showJournal { reembedding.refreshJournal(app) }
                }
                .buttonStyle(showJournal ? .chromaPrimary : .chromaNormal)
                .help(String(localized: "История операций re-embedding: что, когда, какой моделью и с каким исходом"))
                Button(String(localized: "Очистить")) { app.log.clear() }
                    .buttonStyle(.chromaSecondary)
            }

            HStack(spacing: 10) {
                TextField(String(localized: "Поиск"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 200, maxWidth: 260)

                Picker(String(localized: "Источник"), selection: $category) {
                    Text(String(localized: "Все источники")).tag(String?.none)
                    ForEach(app.log.categories, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 130, maxWidth: 190)

                Picker(String(localized: "Уровень"), selection: $level) {
                    Text(String(localized: "Все уровни")).tag(LogEntry.Level?.none)
                    ForEach(LogEntry.Level.allCases, id: \.self) { item in
                        Text(item.title).tag(LogEntry.Level?.some(item))
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 170)

                Spacer(minLength: 0)
            }
        }
        .padding(16)
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

    /// Вкладка «Хранение»: сколько журналов держать и где они лежат.
    ///
    /// Настройки ротации жили в меню «Хранение» на панели фильтров — то есть
    /// на вкладке «События», под шестерёнкой, где их никто не искал. В макете
    /// это отдельная карточка своей вкладки, ею они и стали.
    private var storageCard: some View {
        SectionCard(
            title: String(localized: "Хранение"),
            subtitle: String(localized: "Сколько журналов держать на диске. Старше срока или сверх предела — удаляется без спроса."),
            help: String(localized: "Файл на диске переживает перезапуск приложения, окно «Событий» — нет: на экране показаны записи текущей сессии. Токены и ключи маскируются до записи, а не при показе.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                storageRow(String(localized: "Размер файла")) {
                    Picker("", selection: Binding(
                        get: { settings.configuration.logRetention.megabytesPerFile },
                        set: { settings.configuration.logRetention.megabytesPerFile = $0; applyRetention() }
                    )) {
                        ForEach([5, 10, 25, 100], id: \.self) { Text("\($0.plainDigits) МБ").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                storageRow(String(localized: "Файлов хранить")) {
                    Picker("", selection: Binding(
                        get: { settings.configuration.logRetention.filesKept },
                        set: { settings.configuration.logRetention.filesKept = $0; applyRetention() }
                    )) {
                        ForEach([2, 5, 10, 20], id: \.self) { Text($0.plainDigits).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                storageRow(String(localized: "Строк на экране")) {
                    Picker("", selection: Binding(
                        get: { settings.configuration.logRetention.inMemoryLines },
                        set: { settings.configuration.logRetention.inMemoryLines = $0; applyRetention() }
                    )) {
                        ForEach([1000, 5000, 20000], id: \.self) { Text($0.plainDigits).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Divider()

                Text(app.log.logFileURL?.path ?? AppPaths.logsDirectory.path)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.captionText)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Button(String(localized: "Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            app.log.logFileURL ?? AppPaths.logsDirectory
                        ])
                    }
                    .buttonStyle(.chromaNormal)
                    Spacer()
                }
            }
        }
    }

    private func storageRow<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.Font.control)
                .frame(width: 160, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// Список событий приложения — то, ради чего этот экран открывают.
    @ViewBuilder
    private var eventsList: some View {
        VStack(spacing: 0) {
            if showJournal { journalSection }

            Divider()

            if entries.isEmpty {
                // Без иконки: пустое состояние объясняется словами, а
                // картинка размером с заголовок только оттягивает взгляд.
                VStack(spacing: 6) {
                    Text(String(localized: "Записей нет"))
                        .font(Theme.Font.cardTitle)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    Text(String(localized: "Здесь появится то, что приложение делает прямо сейчас."))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.captionText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LogBlock(caption: String(localized: "Журнал событий")) {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(entries) { entry in
                                    // `formatted` already carries the level
                                    // symbol — the same string the copy button
                                    // puts on the clipboard.
                                    // The timestamp is dimmer than the message
                                    // it introduces; the copy button still puts
                                    // the whole `formatted` line on the clipboard.
                                    // The marker is a plain glyph carrying its
                                    // meaning in colour — green ✓ for success,
                                    // a dot for info, accent for the rest — and
                                    // never a frame around it.
                                    (Text(Self.time.string(from: entry.date))
                                        .foregroundColor(Theme.Palette.logTimestamp)
                                     + Text("  \(entry.level.symbol) ")
                                        .foregroundColor(Self.markerColour(entry.level))
                                     + Text("[\(entry.category)] ")
                                        .foregroundColor(Theme.Palette.logTimestamp)
                                     + Text(entry.message)
                                        .foregroundColor(entry.level == .error || entry.level == .warning
                                                         ? Color.primary.opacity(0.8)
                                                         : Theme.Palette.logText))
                                        .font(Theme.Font.mono)
                                        .lineSpacing(3)
                                        .copyable(entry.formatted)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(entry.id)
                                }
                            }
                        }
                        .pageContentPadding()
                        .padding(.top, 8)
                    }
                    .onChange(of: entries.count) { _, _ in
                        if let last = entries.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text(String(localized: "Записи дублируются в файл; токены маскируются."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                Spacer()
                if let url = app.log.logFileURL {
                    Text(url.path).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var logCard: some View {
        SectionCard(
            title: String(localized: "Вывод сервера"),
            subtitle: String(localized: "То, что процесс chroma печатает сам.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(String(localized: "Фильтр"), text: $serverModel.filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Toggle(String(localized: "Следить за концом"), isOn: $serverModel.followsTail)
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button(String(localized: "Скопировать")) { serverModel.copyLog(processManager.recentOutput) }
                        .disabled(processManager.recentOutput.isEmpty)
                    Menu(String(localized: "Файлы")) {
                        if serverModel.pastRuns.isEmpty {
                            Text(String(localized: "Пока нет записей"))
                        }
                        ForEach(serverModel.pastRuns) { run in
                            Button("\(run.startedAt.formatted(date: .abbreviated, time: .standard)) · \(run.sizeText)") {
                                serverModel.revealRun(run)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                let lines = serverModel.visibleLines(processManager.recentOutput)
                ConsoleView(lines: lines, minHeight: 220, autoScroll: serverModel.followsTail, caption: String(localized: "Вывод сервера"))

                if processManager.recentOutput.isEmpty {
                    Text(String(localized: "Пока пусто — сервер ещё не запускался в этой сессии."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                } else if lines.isEmpty {
                    Text(String(localized: "Ни одна строка не подходит под фильтр."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }

                // Verified on chroma 1.4.4: the server prints its banner and
                // then goes quiet — there is no request log and no verbosity
                // switch. Better to say so than to let an empty panel look
                // like a defect.
                Text(String(localized: "ChromaDB печатает только приветствие при запуске и сообщение об ошибке, если падает; отдельных записей по каждому запросу у неё нет. Вывод сохраняется в файл — последние 5 запусков доступны в меню «Файлы»."))
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.captionText)
            }
        }
    }
}
