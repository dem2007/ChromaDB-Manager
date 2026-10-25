import SwiftUI
import ChromaCore

/// «Экран диагностики»: files the last run could not read, files it read
/// with something to say about them, and what can be done about each.
///
/// Everything here comes out of the manifests, not out of a fresh scan: opening
/// diagnostics must not re-read a folder of documents, and the point is to see
/// what the last run actually found.
///
/// Тип Б: таблица с секцией на источник, множественный выбор, фильтр
/// по разряду — сегментами над таблицей. Действия над выбранным — тулбар и
/// контекстное меню, подробности одной находки — инспектор. Кнопок в строках
/// нет: находок тысячи, и по четыре кнопки на строку — это десятки тысяч
/// элементов, из-за которых экран однажды замирал на секунды.
struct DiagnosticsSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: SourcesViewModel

    /// Что показано: находки одного разряда, все находки или файлы,
    /// прочитанные с оговорками.
    enum Scope: Hashable {
        case problems(FileRemedy?)
        case warnings
    }

    @State private var scope: Scope = .problems(nil)
    /// Источник, находки которого показаны; `nil` — все. Находок тысячи,
    /// и в общей таблице источник, о котором речь, терялся.
    @State private var sourceFilter: UUID?
    /// Поиск по пути и причине — без учёта регистра.
    @State private var searchText = ""
    /// Выбранные строки. Ключ — источник и путь: одинаковые пути в разных
    /// источниках — обычное дело.
    @State private var selection: Set<String> = []
    /// Порядок, ширины и видимость колонок — помнит окно (v3).
    @SceneStorage("table.diagnostics.v3") private var columns: TableColumnCustomization<Row>
    /// Закрыт по умолчанию (v5): без выделения он занимал треть экрана ради
    /// одной фразы, а «Причина» обрезалась. Открывается двойным щелчком по
    /// строке или кнопкой тулбара.
    @SceneStorage("diagnostics.inspector.v2") private var showsInspector = false
    /// Ждёт ли подтверждения «Очистить все находки».
    @State private var confirmingClearAll = false

    /// Строка таблицы: находка или файл с оговорками, с его источником.
    struct Row: Identifiable {
        let id: String
        let source: DataSource
        let path: String
        let detail: String
        let noticedAt: Date?
        let problem: FileProblem?
        let entry: ManifestEntry?
    }

    private var sources: [DataSource] { settings.configuration.dataSources }

    /// Источники под фильтром «Источник».
    private var shownSources: [DataSource] {
        guard let sourceFilter else { return sources }
        return sources.filter { $0.id == sourceFilter }
    }

    private func matchesSearch(_ row: Row) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return row.path.localizedCaseInsensitiveContains(query) || row.detail.localizedCaseInsensitiveContains(query)
    }

    private static func key(_ sourceID: UUID, _ path: String) -> String {
        "\(sourceID.uuidString)|\(path)"
    }

    /// Строки, сгруппированные по источнику, — один проход на отрисовку.
    /// Строки таблицы — построенные один раз на набор условий.
    ///
    /// Раньше они строились заново при каждой перерисовке экрана: модель
    /// экрана публикует изменения и во время синхронизации, и при прокрутке
    /// таблица на тысячах находок раз за разом фильтровала и собирала всё.
    @State private var groups: [(source: DataSource, rows: [Row])] = []

    /// От чего зависят строки таблицы.
    private struct GroupsKey: Hashable {
        let revision: Int
        let scope: Scope
        let sourceFilter: UUID?
        let search: String
        let sources: [DataSource]
    }

    private var groupsKey: GroupsKey {
        GroupsKey(revision: model.findingsRevision, scope: scope, sourceFilter: sourceFilter, search: searchText, sources: sources)
    }

    private var computedGroups: [(source: DataSource, rows: [Row])] {
        shownSources.compactMap { source in
            var rows: [Row]
            switch scope {
            case .problems(let remedy):
                rows = (model.problems[source.id] ?? [])
                    .filter { remedy == nil || $0.remedy == remedy }
                    .map {
                        Row(id: Self.key(source.id, $0.relativePath), source: source, path: $0.relativePath,
                            detail: $0.reason, noticedAt: $0.noticedAt, problem: $0, entry: nil)
                    }
            case .warnings:
                rows = (model.warnedFiles[source.id] ?? []).map {
                    Row(id: Self.key(source.id, $0.relativePath), source: source, path: $0.relativePath,
                        detail: $0.warnings.joined(separator: " · "), noticedAt: nil, problem: nil, entry: $0)
                }
            }
            rows = rows.filter(matchesSearch)
            return rows.isEmpty ? nil : (source, rows)
        }
    }

    var body: some View {
        let groups = self.groups
        let rows = groups.flatMap(\.rows)
        let key = groupsKey as AnyHashable
        let picked = rows.filter { selection.contains($0.id) }

        mainContent(rows: rows, picked: picked)
        .toolbar { toolbarContent(picked) }
        .modifier(GroupsRefresh(key: key) { self.groups = computedGroups })
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Файл или причина"))
        // Находки читаются из манифестов; прежде это делал только список
        // «Источников», и открытая первой вкладка была пустой.
        .onAppear { model.refreshManifests(app) }
        .fittingInspector(isPresented: $showsInspector) {
            Group {
                if picked.count == 1, let row = picked.first {
                    FindingInspector(row: row, model: model)
                } else {
                    InspectorPlaceholder(picked.count > 1
                        ? String(localized: "Выбрано \(picked.count.plainDigits). Решение о выбранном — в тулбаре и контекстном меню.")
                        : String(localized: "Выберите строку в таблице."))
                }
            }
        }
        // Сменились условия — выбор снимается (строки под ним другие).
        .onChange(of: FilterKey(scope: scope, sourceFilter: sourceFilter, search: searchText)) { selection.removeAll() }
        // Источник удалён — фильтр по нему показывал бы пустоту без объяснения.
        .onChange(of: sources.map(\.id)) {
            if let sourceFilter, !sources.contains(where: { $0.id == sourceFilter }) { self.sourceFilter = nil }
        }
        // Профиль подбирается здесь же: окно «Таблицы» живёт на вкладке
        // «Источники», и уходить туда ради одного листа — лишний круг.
        .sheet(isPresented: Binding(
            get: { model.tableMappingSource != nil },
            set: { if !$0 { model.tableMappingSource = nil } }
        )) {
            if let source = sources.first(where: { $0.id == model.tableMappingSource }) {
                TableMappingSheet(model: model.tableMapping, source: source) {
                    model.tableMappingSource = nil
                }
            }
        }
        .confirmationDialog(
            String(localized: "Очистить все находки диагностики?"),
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Очистить"), role: .destructive) {
                model.forgetAllProblems(app)
                selection.removeAll()
            }
            Button(String(localized: "Отменить"), role: .cancel) { confirmingClearAll = false }
        } message: {
            Text(String(localized: "Список опустеет: находок — \(model.problemCount.plainDigits). Файлы останутся в источниках, ничего не исключается и из базы ничего не удаляется. Если файл снова не прочитается, следующий запуск скажет о нём опять."))
        }
        .sheet(isPresented: Binding(
            get: { model.passwordFor != nil },
            set: { if !$0 { model.passwordFor = nil } }
        )) {
            passwordSheet
        }
    }

    private struct FilterKey: Equatable {
        let scope: Scope
        let sourceFilter: UUID?
        let search: String
    }

    @ViewBuilder
    private func mainContent(rows: [Row], picked: [Row]) -> some View {
        VStack(spacing: 0) {
            if model.problemCount == 0 && model.warnedFileCount == 0 {
                ContentUnavailableView {
                    Label(String(localized: "Замечаний нет"), systemImage: "checkmark.circle")
                } description: {
                    Text("Последний запуск прочитал все файлы без оговорок. Приложение ничего не перечитывает, открывая эту вкладку, — показано состояние после последнего запуска.")
                }
            } else {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "Под фильтр ничего не подходит"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Выберите «Все» в меню «Причина» и «Источник» в тулбаре или очистите поиск.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    table(groups)
                }
                footer(total: rows.count, picked: picked.count)
            }
        }
    }

    // MARK: - Фильтр

    /// Разряд находки — то, чем файлы похожи, и решение о них обычно одно на
    /// весь разряд: полтора десятка сканов исключают вместе или включают
    /// распознавание источника. Выбор разряда сразу показывает
    /// только его — пять «читать нечем» среди двух тысяч «сбоев чтения»
    /// иначе не найти.
    private var scopeBar: some View {
        let all = shownSources.flatMap { model.problems[$0.id] ?? [] }
        let byKind = Dictionary(grouping: all, by: \.remedy)
        // Меню, а не сегменты (v3): пять сегментов со счётчиками были
        // шире окна. Счётчик — в пункте меню.
        return Picker(String(localized: "Причина"), selection: $scope) {
            Text("Все · \(all.count.plainDigits)").tag(Scope.problems(nil))
            ForEach(FileRemedy.allCases, id: \.self) { remedy in
                if let group = byKind[remedy] {
                    Text("\(remedy.groupTitle) · \(group.count.plainDigits)").tag(Scope.problems(remedy))
                }
            }
            let warned = shownSources.reduce(0) { $0 + (model.warnedFiles[$1.id]?.count ?? 0) }
            if warned > 0 || scope == .warnings {
                Text("С оговорками · \(warned.plainDigits)").tag(Scope.warnings)
            }
        }
        .pickerStyle(.menu)
        .help(String(localized: "Какие находки показать"))
        .disabled(model.problemCount == 0 && model.warnedFileCount == 0)
    }

    /// Источники, у которых есть что показать, — со счётчиком.
    private var sourceBar: some View {
        Picker(String(localized: "Источник"), selection: $sourceFilter) {
            Text("Все источники").tag(UUID?.none)
            ForEach(sources) { source in
                let count = (model.problems[source.id]?.count ?? 0) + (model.warnedFiles[source.id]?.count ?? 0)
                if count > 0 || source.id == sourceFilter {
                    Text("\(source.name) · \(count.plainDigits)").tag(UUID?.some(source.id))
                }
            }
        }
        .pickerStyle(.menu)
        .help(String(localized: "Находки какого источника показать"))
        .disabled(model.problemCount == 0 && model.warnedFileCount == 0)
    }

    // MARK: - Таблица

    private func table(_ groups: [(source: DataSource, rows: [Row])]) -> some View {
        Table(of: Row.self, selection: $selection, columnCustomization: $columns) {
            TableColumn(String(localized: "Файл")) { row in
                Text(row.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.path)
            }
            // С потолком: остаток — «Причине», её текст длиннее (v4 A6).
            .width(min: 140, ideal: 200, max: 320)
            .customizationID("diagnostics.файл")
            TableColumn(scope == .warnings ? String(localized: "Оговорки") : String(localized: "Причина")) { row in
                Text(row.detail)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(row.detail)
            }
            .customizationID("diagnostics.detail")
            TableColumn(scope == .warnings ? String(localized: "Экстрактор") : String(localized: "Замечено")) { row in
                if let noticed = row.noticedAt {
                    // Без года: с ним время в колонке обрезалось. Полностью —
                    // в подсказке и в инспекторе.
                    Text(noticed.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .foregroundStyle(.secondary)
                        .help(noticed.formatted(date: .abbreviated, time: .shortened))
                } else if let entry = row.entry, !entry.extractorID.isEmpty {
                    Text(verbatim: "\(entry.extractorID) v\(entry.extractorVersion)")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 110, ideal: 140, max: 200)
            .customizationID("diagnostics.when")
        } rows: {
            ForEach(groups, id: \.source.id) { group in
                Section {
                    ForEach(group.rows) { row in
                        SwiftUI.TableRow(row)
                    }
                } header: {
                    Text("\(group.source.name) → \(CollectionNaming.sanitize(group.source.collectionName)) · \(group.rows.count.plainDigits)")
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = groups.flatMap(\.rows).filter { ids.contains($0.id) }
            if scope != .warnings, !chosen.isEmpty {
                decisionButtons(chosen)
            }
            // Одна причина у сотен строк — обычное дело: «листу подходит
            // несколько профилей», «колонки … не найдены». Решение о них
            // одно, и выбирать их по одной незачем.
            if chosen.count == 1, let row = chosen.first {
                let same = groups.flatMap(\.rows).filter { $0.detail == row.detail }
                if same.count > 1 {
                    Divider()
                    Button(String(localized: "Выбрать все с той же причиной (\(same.count.plainDigits))")) {
                        selection = Set(same.map(\.id))
                    }
                }
            }
            if chosen.count == 1, let row = chosen.first, !row.source.isWeb {
                Divider()
                Button(String(localized: "Показать в Finder")) {
                    let url = URL(fileURLWithPath: row.source.path).appendingPathComponent(row.path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } primaryAction: { ids in
            selection = ids
            showsInspector = true
        }
        .onDeleteCommand {
            let chosen = groups.flatMap(\.rows).filter { selection.contains($0.id) }
            if scope != .warnings, !chosen.isEmpty { forget(chosen) }
        }
    }

    /// Строка под таблицей: сколько всего и сколько выбрано.
    private func footer(total: Int, picked: Int) -> some View {
        TableFooter(
            picked > 0
                ? String(localized: "Выбрано \(picked.plainDigits) из \(total.plainDigits)")
                : String(localized: "Строк: \(total.plainDigits)"),
            help: scope == .warnings
                ? String(localized: "Эти файлы проиндексированы. Предупреждение — не ошибка: оно говорит, насколько доверять тексту и структуре.")
                : String(localized: "Эти файлы не прочитаны, и в базу из них ничего не попало. Файл с текстовым слоем читается напрямую; PDF-картинка требует распознавания, а .pages и .numbers — экспорта средствами самих программ. Пока разрешение на автоматизацию не выдано, такие файлы попадают сюда.")
        )
    }

    // MARK: - Действия

    /// Решения о выбранном. Их два, и оба честные: «исключить» меняет
    /// источник — файл перестанет читаться; «убрать из списка» не меняет
    /// ничего, кроме самого списка, и следующий прогон скажет о файле снова.
    /// «Повторить» — синхронизация источников выбранных находок.
    @ViewBuilder
    private func decisionButtons(_ chosen: [Row]) -> some View {
        let chosenSources = Dictionary(grouping: chosen, by: { $0.source.id }).compactMap { $0.value.first?.source }
        Button(FileRemedy.retry.title) {
            for source in chosenSources { model.retry(source, app: app) }
        }
        .disabled(!app.connection.isConnected || chosenSources.contains { model.isBusy($0.id) })
        let scans = chosen.filter { $0.problem?.remedy == .enableOCR && !$0.source.ocrEnabled }
        if !scans.isEmpty {
            Button(FileRemedy.enableOCR.title) {
                for source in Dictionary(grouping: scans, by: { $0.source.id }).compactMap({ $0.value.first?.source }) {
                    model.enableOCR(for: source, app: app)
                }
            }
        }
        let sheets = chosen.filter { $0.problem?.remedy == .chooseProfile }
        let sheetSources = Dictionary(grouping: sheets, by: { $0.source.id }).compactMap { $0.value.first?.source }
        if sheetSources.contains(where: { !$0.unmatchedSheetsAsText }) {
            Button(FileRemedy.chooseProfile.title) {
                for source in sheetSources { model.writeUnmatchedSheetsAsText(for: source, app: app) }
            }
        }
        if sheetSources.count == 1, let source = sheetSources.first {
            Button(String(localized: "Таблицы…")) { model.tableMappingSource = source.id }
        }
        if chosen.count == 1, let row = chosen.first, let problem = row.problem, problem.remedy == .password {
            Button(FileRemedy.password.title + "…") { model.promptForPassword(problem, source: row.source) }
        }
        Divider()
        Button(FileRemedy.exclude.title) { exclude(chosen) }
        Button(String(localized: "Убрать из списка")) { forget(chosen) }
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ picked: [Row]) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { sourceBar }
        ToolbarItem(placement: .primaryAction) { scopeBar }
        ToolbarItemGroup(placement: .primaryAction) {
            // Кнопки не исчезают у «С оговорками», а гаснут: иначе тулбар
            // перестраивается при смене разряда.
            Button {
                    for source in Dictionary(grouping: picked, by: { $0.source.id }).compactMap({ $0.value.first?.source }) {
                        model.retry(source, app: app)
                    }
                } label: {
                    Label(FileRemedy.retry.title, systemImage: "arrow.clockwise")
                }
                .help(String(localized: "Синхронизировать источники выбранных находок"))
                .disabled(scope == .warnings || picked.isEmpty || !app.connection.isConnected)

                Button {
                    exclude(picked)
                } label: {
                    Label(FileRemedy.exclude.title, systemImage: "minus.circle")
                }
                .help(String(localized: "Исключить выбранные файлы из индексации их источников"))
                .disabled(scope == .warnings || picked.isEmpty)
            Toggle(isOn: $showsInspector) {
                Label(String(localized: "Инспектор"), systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(String(localized: "Показать или скрыть подробности находки"))
            .keyboardShortcut("i", modifiers: [.command, .option])
            Menu {
                if scope != .warnings {
                    Button(String(localized: "Убрать выбранное из списка")) { forget(picked) }
                        .disabled(picked.isEmpty)
                    Divider()
                }
                // Последним и с подтверждением: снимает **все** находки разом.
                Button(String(localized: "Очистить все находки…"), role: .destructive) {
                    confirmingClearAll = true
                }
                .disabled(model.problemCount == 0)
            } label: {
                Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
            }
        }
    }

    /// Исключение идёт источник за источником — одна запись настроек на
    /// каждый, а сообщение об итоге одно на всё выбранное.
    private func exclude(_ chosen: [Row]) {
        var excluded = 0
        for group in Dictionary(grouping: chosen, by: { $0.source.id }).values {
            guard let source = group.first?.source else { continue }
            excluded += model.exclude(group.map(\.path), in: source, app: app)
        }
        model.reportExcluded(excluded)
        selection.removeAll()
    }

    private func forget(_ chosen: [Row]) {
        for (sourceID, rows) in Dictionary(grouping: chosen, by: { $0.source.id }) {
            model.forget(rows.map(\.path), in: sourceID, app: app)
        }
        model.reportForgotten(chosen.count)
        selection.removeAll()
    }

    // MARK: - Password

    private var passwordSheet: some View {
        SheetForm(
            cancel: { model.passwordFor = nil; model.passwordInput = "" },
            confirmTitle: String(localized: "Сохранить"),
            confirmDisabled: model.passwordInput.isEmpty,
            confirm: { model.savePassword(app) }
        ) {
            Section {
                SecureField(String(localized: "Пароль"), text: $model.passwordInput)
            } header: {
                SectionHeader(
                    String(localized: "Пароль к документу"),
                    help: String(localized: "Пароль хранится в Keychain и только там: ни в config.json, ни в манифесте, ни в логах. Перенос настроек его не увозит.")
                )
            } footer: {
                Text(model.passwordFor?.relativePath
                     ?? String(localized: "Документ защищён паролем — без него текст не прочитать."))
            }
        }
    }
}

// MARK: - Инспектор

/// Одна находка: что с файлом, когда замечено и что предлагается сделать.
private struct FindingInspector: View {
    @EnvironmentObject private var app: AppEnvironment
    let row: DiagnosticsSection.Row
    @ObservedObject var model: SourcesViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Источник"), value: row.source.name)
                InspectorField(String(localized: "Файл"), row.path, monospaced: true)
                if let noticed = row.noticedAt {
                    LabeledContent(String(localized: "Замечено"), value: noticed.formatted(date: .abbreviated, time: .shortened))
                }
                if let entry = row.entry, !entry.extractorID.isEmpty {
                    LabeledContent(String(localized: "Экстрактор"), value: "\(entry.extractorID) v\(entry.extractorVersion)")
                }
            }

            if let problem = row.problem {
                Section {
                    Notice(.warning, problem.reason)
                    remedy(problem)
                } header: {
                    Text(problem.remedy.groupTitle)
                }
            } else if let entry = row.entry {
                // Предупреждения не красятся: делать с ними нечего, а цвет
                // в этом приложении означает «есть действие рядом».
                Section {
                    ForEach(Array(entry.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                    }
                } header: {
                    Text("Оговорки")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The suggested action first. Every file can be retried and every file
    /// can be excluded — the classification says what is worth trying, not
    /// what is allowed.
    @ViewBuilder
    private func remedy(_ problem: FileProblem) -> some View {
        switch problem.remedy {
        case .enableOCR:
            HStack {
                if row.source.ocrEnabled {
                    Text("Распознавание у источника уже включено.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(FileRemedy.enableOCR.title) { model.enableOCR(for: row.source, app: app) }
                    .disabled(row.source.ocrEnabled)
            }
        case .password:
            HStack {
                // Only the fact, never a verdict: whether the stored password
                // worked is what the reason line says, and it is the run that
                // knows it.
                if app.documentPasswords.has(sourceID: row.source.id, relativePath: problem.relativePath) {
                    Text("Пароль сохранён.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(FileRemedy.password.title + "…") { model.promptForPassword(problem, source: row.source) }
            }
        case .retry, .exclude:
            HStack {
                Spacer()
                Button(FileRemedy.retry.title) { model.retry(row.source, app: app) }
                    .disabled(model.isBusy(row.source.id) || !app.connection.isConnected)
            }
        case .chooseProfile:
            // Повтор без перемены ничего не даст: нужен профиль,
            // под который лист подойдёт, или запись текстом.
            Text("Лист ждёт профиля. Подберите или сохраните профиль в окне «Таблицы…» источника — тогда строки листа станут записями с колонками; или запишите такие листы текстом: поиск найдёт их, но фильтров по колонкам не будет.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "Таблицы…")) { model.tableMappingSource = row.source.id }
                Button(FileRemedy.chooseProfile.title) { model.writeUnmatchedSheetsAsText(for: row.source, app: app) }
                    .disabled(row.source.unmatchedSheetsAsText)
            }
        case .fixRule:
            // Файл читается, но правило источника не ведёт его ни в одну
            // коллекцию: чинится в настройках источника, а не здесь.
            Text("Поправьте правило в настройках источника — поле «Регулярное выражение по относительному пути» рядом с «Режимом маппинга», — затем повторите.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(FileRemedy.retry.title) { model.retry(row.source, app: app) }
                    .disabled(model.isBusy(row.source.id) || !app.connection.isConnected)
            }
        }
    }
}

/// Перестроить строки «Диагностики», когда сменились их условия.
/// Отдельным модификатором: в теле экрана компилятор не успевал разобрать
/// ещё одно звено цепочки.
private struct GroupsRefresh: ViewModifier {
    let key: AnyHashable
    let refresh: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: key, initial: true) { refresh() }
    }
}
