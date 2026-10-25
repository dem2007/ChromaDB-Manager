import SwiftUI
import ChromaCore

struct EnvironmentStatusView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: EnvironmentViewModel
    /// Какой разрез экрана открыт: «Проверки», «Установка», «Копии», «Данные».
    var tab: Int = 0

    /// «Вывод команд» раскрыт — сам раскрывается, когда команда пошла.
    @State private var showsConsole = false
    /// Выбранные резервные копии.
    @State private var selectedBackups: Set<BackupRecord.ID> = []
    /// Порядок, ширины и видимость колонок — помнит окно (v3).
    @SceneStorage("table.backups.v3") private var backupColumns: TableColumnCustomization<BackupRecord>
    /// Копии, удаление которых ждёт подтверждения.
    @State private var backupsToDelete: [BackupRecord] = []
    @State private var confirmingMaintenance = false
    @State private var confirmingWipe = false

    var body: some View {
        Group {
            switch tab {
            case 0:
                installForm
            case 1:
                backupsScreen
            default:
                dataForm
            }
        }
        .sheet(isPresented: $model.showStandaloneConfirmation) { standaloneConfirmation }
        .sheet(isPresented: $model.showUpgradeSheet) { upgradeSheet }
        .task {
            model.refreshBackups(app)
            await model.probeMaintenance(app)
        }
    }

    // MARK: - Сообщения

    @ViewBuilder
    private var messagesSection: some View {
        if model.verificationFailed {
            Section {
                Notice(.warning, String(localized: "Обновление не прошло проверку целостности. Восстановите резервную копию — список ниже."))
            }
        }
        ForEach(messages, id: \.text) { message in
            Section {
                LabeledContent {
                    Button(String(localized: "Скрыть"), action: message.dismiss)
                        .buttonStyle(.borderless)
                } label: {
                    Notice(message.kind, message.text)
                }
            }
        }
    }

    private struct Message {
        let kind: Notice.Kind
        let text: String
        let dismiss: () -> Void
    }

    private var messages: [Message] {
        var list: [Message] = []
        if let error = model.errorMessage { list.append(Message(kind: .warning, text: error) { model.errorMessage = nil }) }
        if let hint = model.hint { list.append(Message(kind: .warning, text: hint) { model.hint = nil }) }
        if let info = model.infoMessage { list.append(Message(kind: .info, text: info) { model.infoMessage = nil }) }
        return list
    }

    // MARK: - Установка

    /// «Установка → Установка»: чего не хватает, потом — как это поставить
    ///. Процессы chroma от прошлых запусков — на «Обзоре»,
    /// проверка обновлений при запуске — в «Настройках».
    private var installForm: some View {
        Form {
            messagesSection
            checksSection
            installSection
            consoleSection
            Section {
                HowItWorks(screen: "environment.install", String(localized: """
                Приложение запускает у вас те же команды, что вы выполняли бы в терминале: скачивание \
                бинарника Chroma CLI, python3 -m venv, pip install, chroma run. Каждая команда печатается \
                в выводе до запуска, а её вывод виден в реальном времени и попадает в раздел «Логи». \
                Приложение не работает в песочнице — иначе оно не смогло бы запускать эти процессы. \
                Сеть используется только для загрузки движка, проверки версий и обращений к вашим локальным \
                ChromaDB и LM Studio.
                """))
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.isBusy) { _, busy in
            if busy { showsConsole = true }
        }
        // Повторная проверка окружения — в тулбаре (v6): в форме остаётся
        // одна кнопка «Проверить» — у строки обновлений.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh(app, checkUpdates: false) }
                } label: {
                    Label(String(localized: "Проверить заново"), systemImage: "arrow.clockwise")
                }
                .help(String(localized: "Проверить окружение заново"))
                .disabled(model.isBusy)
            }
        }
    }

    private var checksSection: some View {
        let items = app.environmentStatus.items(for: settings.configuration.preferredInstallPath)
        return Section {
            ForEach(items) { item in
                checkRow(item)
            }
            if model.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.busyTitle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Остановить")) { model.cancel() }
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Проверки"),
                help: String(localized: "Движок — это Chroma CLI: именно он запускает сервер. Автономному бинарнику Python не нужен вовсе, поэтому при нём проверки Python, pip и пакета chromadb не показываются: они не о вашем случае.")
            )
        } footer: {
            // Проверки — того способа установки, что выбран ниже.
            Text(app.environmentStatus.checkedAt.map {
                String(localized: "Проверено в \($0.formatted(date: .omitted, time: .shortened)) для способа «\(settings.configuration.preferredInstallPath.title)».")
            } ?? String(localized: "Идёт первая проверка…"))
        }
    }

    private func checkRow(_ item: CheckItem) -> some View {
        LabeledContent {
            if let action = action(for: item) {
                Button(action.title, action: action.handler)
            }
        } label: {
            VStack(alignment: .leading) {
                StatusLabel(Self.status(item.state), item.title)
                    .accessibilityValue(Self.stateWord(item.state))
                // Путь — моноширинным, в одну строку с многоточием посередине,
                // как везде; остальное описание — обычным текстом.
                ForEach(Array(item.detail.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("/") || line.hasPrefix("~") {
                        Text(String(line))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(String(line))
                    } else {
                        Text(String(line))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let hint = item.hint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func status(_ state: CheckState) -> StatusLabel.State {
        switch state {
        case .ok: return .ok
        case .warning: return .warning
        case .missing: return .error
        case .unknown, .checking: return .off
        }
    }

    private static func stateWord(_ state: CheckState) -> String {
        switch state {
        case .ok: return String(localized: "в порядке")
        case .warning: return String(localized: "требует внимания")
        case .missing: return String(localized: "не найдено")
        case .unknown: return String(localized: "статус не определён")
        case .checking: return String(localized: "проверяется")
        }
    }

    private func action(for item: CheckItem) -> (title: String, handler: () -> Void)? {
        switch item.id {
        case "updates":
            return (String(localized: "Проверить"), { model.checkForUpdates(app) })
        case "engine" where app.environmentStatus.updateAvailable:
            return (String(localized: "Обновить…"), { model.showUpgradeSheet = true })
        case "pip" where app.environmentStatus.pipVersion == nil && app.environmentStatus.activeInterpreter != nil:
            return (String(localized: "Починить pip"), { model.bootstrapPip(app) })
        default:
            return nil
        }
    }

    /// Способов установки ровно два, и они взаимоисключающие:
    /// выбор — радиокнопками, следствие выбранного — под ними.
    private var installSection: some View {
        let path = settings.configuration.preferredInstallPath
        let isStandalone = path == .standalone
        // «Установлено» — про выбранный способ, а не про движок вообще:
        // найденный автономный бинарник ничего не говорит о пакете в venv.
        let isReady = isStandalone
            ? app.environmentStatus.isEngineInstalled
            : app.environmentStatus.chromadbPackageVersion != nil
        return Section {
            Picker(String(localized: "Способ"), selection: $settings.configuration.preferredInstallPath) {
                ForEach([EngineInstallPath.standalone, .managedVenv], id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            // Без подписи — каждый вариант своей строкой, как на «Безопасности»
            // (v6); что выбирается, говорит заголовок секции.
            .labelsHidden()

            if path == .managedVenv {
                pythonRows
            }

            HStack {
                Spacer()
                if isStandalone {
                    Button(isReady ? String(localized: "Переустановить CLI…") : String(localized: "Установить ChromaDB…")) {
                        model.prepareStandaloneInstall(app)
                    }
                } else {
                    Button(isReady ? String(localized: "Переустановить в venv") : String(localized: "Установить в venv")) {
                        model.installIntoVenv(app)
                    }
                }
                Button(String(localized: "Обновить движок…")) {
                    model.showUpgradeSheet = true
                }
                .disabled(!app.environmentStatus.isEngineInstalled)
            }
            .disabled(model.isBusy)
        } header: {
            SectionHeader(
                String(localized: "Установка движка"),
                help: String(localized: "Автономный бинарник берётся из официального релиза проекта на GitHub и кладётся в каталог приложения: в /usr/local/bin нужен sudo, которого у приложения нет. Второй способ — pip install chromadb в отдельное виртуальное окружение приложения; системный Python и Homebrew-питон он не затрагивает (PEP 668).")
            )
        } footer: {
            // Ссылка на официальный скрипт — в подписи (v6), а не слева от
            // кнопок установки.
            HStack(alignment: .firstTextBaseline) {
                Text(installSummary(path))
                if isStandalone {
                    Button(String(localized: "Открыть install.sh")) { model.openInstallScriptPage() }
                        .buttonStyle(.link)
                        .help(InstallationService.officialInstallScriptURL.absoluteString)
                }
            }
        }
    }



    private func installSummary(_ path: EngineInstallPath) -> String {
        switch path {
        case .standalone:
            return String(localized: "Готовый бинарник из релиза проекта. Python не нужен вовсе.")
        case .managedVenv:
            return String(localized: "Пакет chromadb в собственном окружении приложения. Нужен Python 3.")
        }
    }

    /// Параметры второго способа: чем создавать venv и где взять Python.
    @ViewBuilder
    private var pythonRows: some View {
        if app.environmentStatus.interpreters.isEmpty {
            LabeledContent(String(localized: "Python")) {
                Text("не найден")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker(String(localized: "Базовый интерпретатор для venv"), selection: Binding(
                get: { settings.configuration.preferredPythonPath ?? app.environmentStatus.activeInterpreter?.path ?? "" },
                set: { newValue in
                    settings.configuration.preferredPythonPath = newValue
                    Task { await model.refresh(app, checkUpdates: false) }
                }
            )) {
                ForEach(app.environmentStatus.interpreters) { interpreter in
                    Text(interpreter.displayName).tag(interpreter.path)
                }
            }
        }
        HStack {
            Spacer()
            Menu(String(localized: "Установить Python")) {
                Button(String(localized: "Через Homebrew")) { model.installPythonWithHomebrew(app) }
                    .disabled(app.environmentStatus.homebrewPath == nil || model.isBusy)
                Button(String(localized: "Скачать с python.org")) { model.openPythonDownloadPage() }
            }
            .fixedSize()
            .help(app.environmentStatus.homebrewPath.map { "\($0) install python@3.12" }
                  ?? String(localized: "Homebrew не найден в системе"))
        }
    }

    /// Вывод команд — свёрнут, пока ничего не запущено; раскрывается сам,
    /// когда команда пошла.
    private var consoleSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsConsole) {
                LogView(lines: model.consoleLines, compact: true)
                HStack {
                    Spacer()
                    Button(String(localized: "Очистить")) { model.clearConsole() }
                        .disabled(model.consoleLines.isEmpty)
                }
            } label: {
                Text("Вывод команд")
                    .togglesDisclosure($showsConsole)
            }
        }
    }

    // MARK: - Резервные копии

    private var selectedBackupRecords: [BackupRecord] {
        model.backups.filter { selectedBackups.contains($0.id) }
    }

    /// Одна выбранная и целая — из неё можно восстановить.
    private var restorableSelection: BackupRecord? {
        let chosen = selectedBackupRecords
        guard chosen.count == 1, let backup = chosen.first, !backup.isIncomplete else { return nil }
        return backup
    }

    /// «Установка → Резервные копии»: тип Б — таблица копий, действия над
    /// выделенным в тулбаре, контекстном меню и с клавиатуры.
    private var backupsScreen: some View {
        VStack(spacing: 0) {
            if !messages.isEmpty || model.verificationFailed {
                VStack(alignment: .leading) {
                    if model.verificationFailed {
                        Notice(.warning, String(localized: "Обновление не прошло проверку целостности. Восстановите резервную копию — список ниже."))
                    }
                    ForEach(messages, id: \.text) { message in
                        HStack {
                            Notice(message.kind, message.text)
                            Spacer()
                            Button(String(localized: "Скрыть"), action: message.dismiss)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding()
                Divider()
            }

            // Строки однострочные (v3): состояние копии — своей колонкой.
            Table(model.backups, selection: $selectedBackups, columnCustomization: $backupColumns) {
                TableColumn(String(localized: "Копия")) { backup in
                    Text(backup.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(backup.name)
                }
                .customizationID("name")
                // Имя копии — та же дата, что в соседней колонке (v4 B):
                // по умолчанию скрыто, полностью — в подсказке даты.
                .defaultVisibility(.hidden)
                TableColumn(String(localized: "Дата")) { backup in
                    Text(backup.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                        .monospacedDigit()
                        .help(backup.name)
                }
                // Главная колонка, пока имя скрыто, — без ширины: остаток
                // таблицы её, а не пустой хвост справа (v3).
                .customizationID("date")
                TableColumn(String(localized: "Размер")) { backup in
                    Text(backup.sizeText)
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 130)
                .alignment(.numeric)
                .customizationID("size")
                TableColumn(String(localized: "Состояние")) { backup in
                    // Прерванная копия выглядит как целая в списке имён и
                    // размеров — поэтому говорит о себе сама.
                    if backup.isIncomplete {
                        StatusLabel(.error, String(localized: "повреждена"))
                            .help(String(localized: "повреждена, восстановление недоступно"))
                    }
                    // Целая копия — пустая ячейка: колонка из одних «целая»
                    // была шумом (v4 A6); повреждённая видна сразу.
                }
                .width(min: 100, ideal: 150, max: 210)
                .customizationID("state")
                // Видна по умолчанию, только когда есть повреждённая копия
                // (v5): колонка из пустых ячеек с одним заголовком была шумом.
                .defaultVisibility(model.backups.contains(where: \.isIncomplete) ? .visible : .hidden)
            }
            .contextMenu(forSelectionType: BackupRecord.ID.self) { ids in
                let chosen = model.backups.filter { ids.contains($0.id) }
                if chosen.count == 1, let backup = chosen.first {
                    Button(String(localized: "Восстановить…")) { model.askToRestore(backup, app: app) }
                        .disabled(backup.isIncomplete || model.isBusy)
                    Button(String(localized: "Показать в Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([backup.url])
                    }
                }
                if !chosen.isEmpty {
                    Divider()
                    Button(String(localized: "Удалить…"), role: .destructive) { backupsToDelete = chosen }
                }
            } primaryAction: { ids in
                if ids.count == 1, let backup = model.backups.first(where: { ids.contains($0.id) }), !backup.isIncomplete {
                    model.askToRestore(backup, app: app)
                }
            }
            .onDeleteCommand { backupsToDelete = selectedBackupRecords }
            .overlay {
                if model.backups.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "Копий пока нет"), systemImage: "externaldrive")
                    } description: {
                        Text("Копия снимается при остановленном сервере и ждёт своей очереди.")
                    } actions: {
                        Button(String(localized: "Сделать копию")) { model.makeBackupNow(app) }
                            .disabled(model.isBusy || model.backupTarget(app) == nil)
                    }
                }
            }

            Divider()
            HStack {
                // Сколько нужно и сколько есть — до того, как что-то
                // скопировано.
                if let space = model.backupSpace(app) {
                    if space.fits {
                        Text(String(localized: "Нужно \(space.requiredText), свободно \(space.availableText)"))
                            .foregroundStyle(.secondary)
                    } else {
                        Notice(.warning, String(localized: "Недостаточно места: нужно \(space.requiredText), свободно \(space.availableText)"))
                    }
                }
                if let result = model.lastMaintenance {
                    Text(result.summary).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.busyTitle).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.makeBackupNow(app)
                } label: {
                    Label(String(localized: "Сделать копию"), systemImage: "plus")
                }
                .disabled(model.isBusy || model.backupTarget(app) == nil)
                .help(String(localized: "Сделать копию базы сейчас"))

                Button {
                    if let backup = restorableSelection { model.askToRestore(backup, app: app) }
                } label: {
                    Label(String(localized: "Восстановить…"), systemImage: "clock.arrow.circlepath")
                }
                .disabled(restorableSelection == nil || model.isBusy)
                .help(String(localized: "Восстановить базу из выбранной копии"))

                Button {
                    backupsToDelete = selectedBackupRecords
                } label: {
                    Label(String(localized: "Удалить…"), systemImage: "trash")
                }
                .disabled(selectedBackups.isEmpty)
                .help(String(localized: "Удалить выбранные копии"))

                Menu {
                    Button(String(localized: "Показать в Finder")) {
                        let urls = selectedBackupRecords.map(\.url)
                        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [AppPaths.backupsDirectory] : urls)
                    }
                    Button(String(localized: "Обновить список")) { model.refreshBackups(app) }
                    // Сжатие — только когда CLI его умеет и файлы базы
                    // приложению доступны.
                    if model.maintenanceAvailable, model.backupTarget(app) != nil {
                        Divider()
                        Button(String(localized: "Сжать базу…")) { confirmingMaintenance = true }
                            .disabled(model.isBusy)
                    }
                } label: {
                    Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
                }
                .help(String(localized: "Ещё"))
            }
        }
        // Вопрос — о **тех самых** копиях: имя, дата и размер в тексте.
        .confirmationDialog(
            backupsToDelete.count == 1
                ? String(localized: "Удалить копию?")
                : String(localized: "Удалить копии: \(backupsToDelete.count.plainDigits)?"),
            isPresented: Binding(get: { !backupsToDelete.isEmpty }, set: { if !$0 { backupsToDelete = [] } }),
            titleVisibility: .visible,
            presenting: backupsToDelete
        ) { chosen in
            Button(String(localized: "Удалить"), role: .destructive) {
                for backup in chosen { model.delete(backup, app: app) }
                selectedBackups = []
                model.refreshBackups(app)
            }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: { chosen in
            Text(chosen.count == 1
                 ? String(localized: "\(chosen[0].name) — \(chosen[0].createdAt.formatted(date: .abbreviated, time: .shortened)), \(chosen[0].sizeText). Копия удаляется с диска навсегда; восстановить базу из неё будет нельзя.")
                 : String(localized: "Копии удаляются с диска навсегда; восстановить базу из них будет нельзя."))
        }
        .background {
            // Отдельным видом: два диалога на одном виде SwiftUI показывает
            // не всегда.
            Color.clear.confirmationDialog(
                String(localized: "Восстановить базу из копии?"),
                isPresented: Binding(
                    get: { model.pendingRestore != nil },
                    set: { if !$0 { model.pendingRestore = nil } }
                ),
                titleVisibility: .visible,
                presenting: model.pendingRestore
            ) { backup in
                Button(String(localized: "Восстановить"), role: .destructive) {
                    model.restore(backup, app: app)
                }
                Button(String(localized: "Отменить"), role: .cancel) { model.pendingRestore = nil }
            } message: { backup in
                Text(String(localized: "\(backup.name) — \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)). Текущая база будет заменена содержимым копии; сама она отложится в папку копий."))
            }
        }
        .background {
            Color.clear.confirmationDialog(
                String(localized: "Сжать базу?"),
                isPresented: $confirmingMaintenance,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Сжать")) { model.runMaintenance(app) }
                Button(String(localized: "Отменить"), role: .cancel) {}
            } message: {
                Text(String(localized: "Резервная копия → остановка сервера → сжатие → запуск → проверка. Займёт примерно как копирование базы (сейчас \(ByteCountFormatter.string(fromByteCount: model.databaseSize(app), countStyle: .file))). Идёт общей очередью: если что-то индексируется, сжатие дождётся конца."))
            }
        }
    }

    // MARK: - Управление данными

    /// «Установка → Управление данными»: удаление того, что создало
    /// приложение. Версия, обновления, перенос настроек и строка меню —
    /// в «Настройках».
    private var dataForm: some View {
        Form {
            messagesSection
            Section {
                LabeledContent(String(localized: "Версия приложения"),
                               value: AppUpdateChecker.currentVersion() ?? String(localized: "неизвестна"))
                LabeledContent(String(localized: "Обновления, перенос настроек, строка меню")) {
                    SettingsLink { Text("Изменить в Настройках…") }
                        .buttonStyle(.link)
                }
            } header: {
                Text("Приложение")
            }

            wipeSection
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        // «Удалить все данные» — с перечнем, с базами, названными
        // нетронутыми, и со словом, которое надо ввести.
        .alert(String(localized: "Удалить все данные приложения?"), isPresented: $confirmingWipe) {
            TextField(String(localized: "введите УДАЛИТЬ"), text: $model.wipeConfirmation)
            Button(String(localized: "Удалить"), role: .destructive) {
                if wipeIsConfirmed { model.wipeAllData(app) }
            }
            .disabled(!wipeIsConfirmed)
            Button(String(localized: "Отменить"), role: .cancel) { model.wipeConfirmation = "" }
        } message: {
            Text("Удаление необратимо. Ваши базы данных остаются на месте. Чтобы подтвердить, введите УДАЛИТЬ.")
        }
    }

    private var wipeIsConfirmed: Bool {
        CollectionsViewModel.confirms(model.wipeConfirmation, word: String(localized: "УДАЛИТЬ"), russian: "УДАЛИТЬ")
    }

    @ViewBuilder
    private var wipeSection: some View {
        let plan = model.wipePlan(app)
        Section {
            ForEach(plan) { item in
                VStack(alignment: .leading) {
                    if item.isOptional {
                        // Подпись говорит, что делает переключатель (v6).
                        Toggle(String(localized: "Удалить и резервные копии"), isOn: $model.wipeIncludesBackups)
                    } else {
                        LabeledContent(item.title, value: item.sizeText ?? "")
                    }
                    // Моноширинным — только путь («все записи приложения» —
                    // не путь).
                    Text(item.detail)
                        .font(item.detail.hasPrefix("/") ? .callout.monospaced() : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.detail)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Удалить все данные…"), role: .destructive) {
                    model.wipeConfirmation = ""
                    confirmingWipe = true
                }
                .destructiveTextStyle()
                .disabled(model.isBusy)
            }
        } header: {
            Text("Удаление данных приложения")
        } footer: {
            // Одно предупреждение на секцию (v6): про движок — здесь же, а не
            // вторым под строкой.
            Notice(.warning, ([String(localized: "Удаляет то, что создало приложение, — безвозвратно. Ваши базы данных остаются на месте.")]
                              + plan.compactMap(\.note)).joined(separator: " "))
        }

        let untouched = model.wipeUntouchedPaths(app)
        if !untouched.isEmpty {
            Section {
                ForEach(untouched, id: \.self) { path in
                    Text(path)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            } header: {
                Text("Не удаляется ни при каких условиях")
            }
        }
    }

    // MARK: - Sheets

    private var standaloneConfirmation: some View {
        SheetForm(
            cancel: { model.showStandaloneConfirmation = false },
            confirmTitle: String(localized: "Скачать и установить"),
            confirmDisabled: model.standalonePlan == nil,
            confirm: { model.confirmStandaloneInstall(app) }
        ) {
            if let plan = model.standalonePlan {
                Section {
                    LabeledContent(String(localized: "Версия"), value: plan.version)
                    LabeledContent(String(localized: "Файл"), value: "\(plan.assetName) · \(plan.sizeText)")
                    LabeledContent(String(localized: "Источник")) { monospacedValue(plan.downloadURL.absoluteString) }
                    LabeledContent(String(localized: "Куда")) { monospacedValue(plan.destination.path) }
                } header: {
                    Text("Установка Chroma CLI")
                } footer: {
                    Text("Что будет скачано и куда положено — до того, как что-либо начнётся.")
                }
                Section {
                    Text(plan.equivalentCommand)
                        .font(.body.monospaced())
                        .copyable(plan.equivalentCommand)
                } header: {
                    Text("Будет выполнено")
                }
            }
        }
    }

    private var upgradeSheet: some View {
        SheetForm(
            cancel: { model.showUpgradeSheet = false },
            confirmTitle: String(localized: "Обновить"),
            confirm: { model.upgrade(app) }
        ) {
            Section {
                LabeledContent(String(localized: "Установлено"), value: app.environmentStatus.installedVersion ?? "—")
                LabeledContent(String(localized: "Доступно"), value: app.environmentStatus.latestVersion ?? String(localized: "не проверялось"))
                LabeledContent(String(localized: "Способ"), value: settings.configuration.preferredInstallPath.title)
                if let target = model.backupTarget(app) {
                    LabeledContent(String(localized: "База для копии")) { monospacedValue(target.path) }
                }
            } header: {
                SectionHeader(
                    String(localized: "Обновление движка"),
                    help: String(localized: "Перед обновлением приложение остановит сервер и скопирует каталог базы. После обновления оно проверит, что база открывается и число документов в коллекциях совпадает с зафиксированным.")
                )
            } footer: {
                Text("Миграции формата хранения необратимы, поэтому копия базы снимается до обновления.")
            }
            Section {
                Toggle(String(localized: "Пропустить резервную копию — понимаю риск"), isOn: $model.acknowledgeSkippingBackup)
            } footer: {
                if model.acknowledgeSkippingBackup {
                    Notice(.warning, String(localized: "Без копии неудачную миграцию откатить будет не из чего."))
                }
            }
        }
    }

    private func monospacedValue(_ value: String) -> some View {
        Text(value)
            .font(.body.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .copyable(value)
            .help(value)
    }

    // MARK: - Log panel

}
