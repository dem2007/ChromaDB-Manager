import SwiftUI
import ChromaCore

/// Sources part of the «Эмбеддинги» screen: registered folders, manual sync and
/// what the last run did.
struct SourcesSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var schemaStore: SchemaStore
    @ObservedObject var model: SourcesViewModel
    @ObservedObject var embeddings: EmbeddingsViewModel
    @ObservedObject var autoSync: AutoSyncCoordinator
    /// Перейти на вкладку «Диагностика».
    var openDiagnostics: () -> Void = {}

    /// Какие исчезнувшие файлы отмечены для общего решения.
    /// Ключ — источник и путь: пути в разных источниках совпадают.
    @State private var selectedRemovals: Set<String> = []
    /// Сколько исчезнувших файлов показывать сразу.
    @State private var removalLimit = 50

    /// Порядок — по ходу работы, а не по истории кода.
    ///
    /// Сверху то, из-за чего человек сюда пришёл: что сейчас идёт и что ждёт
    /// его решения. Дальше — действие и то, над чем оно совершается: список
    /// источников, по карточке на каждый. Настройки запуска и объяснения —
    /// в конце, свёрнуто.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if let error = model.errorMessage {
                MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
            }
            if let message = model.infoMessage {
                MessageBanner(kind: .info, text: message) { model.infoMessage = nil }
            }
            // Список источников живёт в config.json. Если файл не прочитался,
            // список на экране пуст — и добавление нового источника ничего не
            // восстановит, а старый файл трогать нельзя.
            if let problem = settings.persistenceProblem {
                MessageBanner(kind: .error, text: problem)
                HStack(spacing: 10) {
                    Button(String(localized: "Перечитать настройки")) { settings.reload() }
                        .buttonStyle(.chromaNormal)
                    Text("Рядом с config.json лежит config.previous.json — предыдущая сохранённая версия.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    Spacer()
                }
            }

            runningCard
            decisionsCard
            diagnosticsCard
            // По карточке на каждый план: источников можно поставить
            // несколько, и у каждого свой ответ на «что это затронет».
            ForEach(orderedPlans, id: \.sourceID) { plan in
                planCard(plan)
            }
            if let summary = model.lastSummary { summaryCard(summary) }

            actionsRow
            if settings.configuration.dataSources.isEmpty {
                emptyCard
            } else {
                ForEach(settings.configuration.dataSources) { source in
                    sourceCard(source)
                }
            }

            chunkingDefaultsSection
            launchRulesSection
            howItWorks
        }
        .onAppear {
            model.refreshManifests(app)
            // Папку могли перетащить на окно ещё до того, как этот экран
            // открылся.
            model.beginEditingDroppedFolder(app)
        }
        .onChange(of: model.pendingDrop) { model.beginEditingDroppedFolder(app) }
        // Папок могло быть несколько: закрыли редактор — открывается
        // следующая, и ни одна не теряется молча.
        .onChange(of: model.draft == nil) { model.beginEditingDroppedFolder(app) }
        // Источник, добавленный или синхронизированный где-то ещё, иначе
        // остался бы с фактами прошлого захода на экран.
        .onChange(of: settings.configuration.dataSources.map(\.id)) {
            model.refreshManifests(app)
        }
        .sheet(isPresented: Binding(
            get: { model.draft != nil },
            set: { if !$0 { model.cancelDraft() } }
        )) {
            SourceEditorSheet(model: model, embeddings: embeddings)
        }
        .sheet(isPresented: Binding(
            get: { model.tableMappingSource != nil },
            set: { if !$0 { model.tableMappingSource = nil } }
        )) {
            if let source = settings.configuration.dataSources.first(where: { $0.id == model.tableMappingSource }) {
                TableMappingSheet(model: model.tableMapping, source: source) {
                    model.tableMappingSource = nil
                }
            }
        }
        // Правило 3: сначала список, потом действие. Спрашивается **что именно
        // исчезнет** и что останется — иначе человек согласится, думая, что
        // удаляет коллекцию, или откажется, думая, что удаляет папку с диска.
        .confirmationDialog(
            model.sourcePendingRemoval.map { String(localized: "Убрать источник «\($0.name)» из списка?") } ?? "",
            isPresented: Binding(
                get: { model.sourcePendingRemoval != nil },
                set: { if !$0 { model.sourcePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Убрать из списка"), role: .destructive) {
                if let source = model.sourcePendingRemoval {
                    model.removeSource(source, app: app)
                }
                model.sourcePendingRemoval = nil
            }
            Button(String(localized: "Отмена"), role: .cancel) { model.sourcePendingRemoval = nil }
        } message: {
            if let source = model.sourcePendingRemoval {
                Text("Папка на диске и документы в коллекции «\(source.collectionName)» останутся нетронутыми. Исчезнут настройки самого источника: стратегия и параметры нарезки, расписания, поля метаданных и профили таблиц — восстановить их будет неоткуда.")
            }
        }
        // столько файлов разом не исчезает по воле человека. Вопрос
        // задаётся отдельно от всех прочих — ответ «да» стоит тысяч
        // документов, и утонуть в строке в углу экрана он не должен.
        .confirmationDialog(
            model.massRemoval.map { String(localized: "Источник «\($0.source.name)»: файлы исчезли с диска") } ?? "",
            isPresented: Binding(
                get: { model.massRemoval != nil },
                set: { if !$0 { model.massRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Подтвердить: файлы действительно удалены"), role: .destructive) {
                if let prompt = model.massRemoval { model.confirmMassRemoval(prompt, app: app) }
                model.massRemoval = nil
            }
            Button(String(localized: "Отмена — проверю диск"), role: .cancel) { model.massRemoval = nil }
        } message: {
            if let prompt = model.massRemoval { Text(prompt.message) }
        }
    }

    /// Shown only when there is something to show: a permanently visible
    /// «диагностика» card with nothing in it teaches the user to ignore it.
    @ViewBuilder
    private var diagnosticsCard: some View {
        if model.problemCount > 0 || model.warnedFileCount > 0 {
            SectionCard(
                title: String(localized: "Диагностика извлечения"),
                subtitle: String(localized: "Что последний запуск не смог прочитать и что прочитал с оговорками.")
            ) {
                HStack(spacing: 14) {
                    if model.problemCount > 0 {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.Palette.attention)
                                .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                            Text("требуют решения: \(model.problemCount.plainDigits)")
                                .font(Theme.Font.control)
                        }
                    }
                    if model.warnedFileCount > 0 {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.Palette.stopped)
                                .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                            Text("с предупреждениями: \(model.warnedFileCount.plainDigits)")
                                .font(Theme.Font.control)
                        }
                    }
                    Spacer()
                    // Соседняя вкладка, а не лист поверх экрана: там та же
                    // диагностика, и лист прятал её вместе с массовыми
                    // действиями, ради которых на неё и заходят.
                    Button(String(localized: "Открыть диагностику")) { openDiagnostics() }
                        .buttonStyle(.chromaNormal)
                }
            }
        }
    }

    // MARK: - Что сейчас

    /// Идущая синхронизация — первое, что видно: ради неё сюда и заходят,
    /// пока она идёт.
    ///
    /// Отдельной вьюхой (см. `SyncProgressRows`): это самый тяжёлый экран
    /// приложения, и перестраивать его четыре раза в секунду ради полоски
    /// прогресса нельзя.
    @ViewBuilder
    private var runningCard: some View {
        if model.isBusy {
            SectionCard(
                title: String(localized: "Идёт синхронизация"),
                subtitle: String(localized: "Модель обслуживает по одному источнику за раз. Остальные можно поставить в очередь и уйти — они пойдут сами, один за другим.")
            ) {
                VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                    SyncProgressRows(label: progressLabel)
                    HStack {
                        // «Все»: у каждого источника есть своя кнопка
                        // «Остановить», и эта обязана отличаться от неё.
                        Button(String(localized: "Остановить все")) { model.cancel() }
                            .buttonStyle(.chromaDanger)
                        Spacer()
                    }
                }
            }
        }
        // Автоматическая индексация на паузе — это состояние, из-за которого
        // источники «не обновляются сами», и оно должно быть видно, а не
        // спрятано в тумблер внизу экрана (правило 2 Приложения 5).
        if settings.configuration.automaticSyncPaused,
           settings.configuration.dataSources.contains(where: { $0.triggers.isAnyEnabled }) {
            HStack(spacing: 12) {
                Circle().fill(Theme.Palette.attention)
                    .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                Text("Автоматическая индексация приостановлена — по расписанию и при изменениях ничего не запустится.")
                    .font(Theme.Font.control)
                Spacer(minLength: 8)
                Button(String(localized: "Возобновить")) { autoSync.setPaused(false, app: app) }
                    .buttonStyle(.chromaNormal)
            }
            .padding(.horizontal, Theme.Padding.rowHorizontal)
            .padding(.vertical, Theme.Padding.rowVertical)
            .background(Theme.Palette.attention.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.banner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.banner)
                    .strokeBorder(Theme.Palette.attention.opacity(0.24), lineWidth: 1)
            )
        }
    }

    // MARK: - Действия и список

    /// Ряд действий над всеми источниками — как в макете, на полотне над
    /// списком, а не внутри карточки.
    private var actionsRow: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Добавить папку")) { model.addSource(app) }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Добавить сайт")) { model.addWebSource(app) }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Добавить репозиторий")) { model.addGitSource(app) }
                .buttonStyle(.chromaNormal)
            Spacer()
            Button(String(localized: "Синхронизировать все")) { model.syncAll(app) }
                .buttonStyle(.chromaPrimary)
                .disabled(model.isSyncingAll || settings.configuration.dataSources.isEmpty || !app.connection.isConnected)
        }
    }

    private var emptyCard: some View {
        SectionCard(
            title: String(localized: "Источников пока нет"),
            subtitle: String(localized: "Источник — это папка, сайт или репозиторий, который становится коллекцией и обновляется по вашей команде.")
        ) {
            Text("Добавьте первый кнопкой выше. Папку можно просто перетащить на окно приложения.")
                .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
        }
    }

    /// Один источник — одна карточка.
    ///
    /// В макете так и нарисовано: имя и путь, справа его действия, ниже — три
    /// строки о том, как он устроен, и строка итога последнего прогона. Раньше
    /// все источники лежали в одной карточке, разделённые линиями, и строка
    /// «Настроить · План · Синхронизировать» тонула среди десяти строк текста.
    private func sourceCard(_ source: DataSource) -> some View {
        let info = model.manifestInfo[source.id]
        let pending = model.pendingRemovals[source.id] ?? []
        let stale = model.staleExtraction[source.id] ?? []

        return SectionCard(title: source.name, subtitle: source.path) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                HStack(spacing: 8) {
                    Button(String(localized: "Настроить")) { model.beginEditing(source) }
                        .buttonStyle(.chromaNormal)
                        .disabled(model.isBusy(source.id))
                    // Only for sources that actually name a table
                    // format: a spreadsheet editor offered on a folder of
                    // Markdown is noise.
                    if source.fileExtensions.contains(where: TabularFormat.allExtensions.contains) {
                        Button(String(localized: "Таблицы")) { model.tableMappingSource = source.id }
                            .buttonStyle(.chromaNormal)
                            .disabled(model.isBusy(source.id))
                    }
                    Button(String(localized: "План")) { model.preview(source, app: app) }
                        .buttonStyle(.chromaNormal)
                        .disabled(model.isBusy(source.id))
                    if model.isBusy(source.id) { ProgressView().controlSize(.small) }
                    Spacer()
                    // Обычная, не синяя: источников на экране дюжина, и дюжина
                    // синих кнопок — это уже не «главное действие», а фон.
                    // Синяя на экране одна — «Синхронизировать все».
                    // Пока идёт этот источник, кнопка снимает **его** работу:
                    // остальные поставленные в очередь идут дальше.
                    if model.isBusy(source.id) {
                        Button(String(localized: "Остановить")) { model.cancel(sourceID: source.id) }
                            .buttonStyle(.chromaSecondary)
                    } else if model.pendingConfirmations.contains(source.id) {
                        // Ворота J2 остановили запуск и ждут подтверждения.
                        // Кнопка называет это здесь, у самого источника: план
                        // с баннером «Подтвердите запуск» лежит **выше**
                        // списка, и человек, нажавший «Синхронизировать» внизу
                        // длинного экрана, не видит ни его, ни причины —
                        // нажатие выглядит потерянным.
                        Button(String(localized: "Подтвердить запуск")) {
                            model.runPlannedSync(source, app: app)
                        }
                        .buttonStyle(.chromaNormal)
                        .disabled(!app.connection.isConnected)
                    } else {
                        Button(String(localized: "Синхронизировать")) { model.sync(source, app: app) }
                            .buttonStyle(.chromaNormal)
                            .disabled(!app.connection.isConnected)
                    }
                    Menu {
                        Button(String(localized: "Убрать источник из списка…"), role: .destructive) {
                            model.sourcePendingRemoval = source
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 30)
                    .help(String(localized: "Убрать источник из списка. Документы в базе останутся."))
                }

                // Как устроен источник: три строки из макета — чем он является,
                // как нарезается, куда пишет и когда запускается.
                VStack(alignment: .leading, spacing: 3) {
                    Text(sourceKindLine(source))
                    Text(targetsText(source, info: info))
                    Text(triggerText(source))
                        .foregroundStyle(source.triggers.isAnyEnabled && settings.configuration.automaticSyncPaused
                                         ? Theme.Palette.attention
                                         : Theme.Palette.captionText)
                }
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

                // Почему запуск остановлен — здесь же, а не только в плане
                // наверху. Причина берётся у самого плана, как и
                // баннер: два своих текста разошлись бы при первой правке
                // порога.
                if model.pendingConfirmations.contains(source.id),
                   let plan = model.plans[source.id] {
                    let reasons = plan.confirmationReasons(
                        threshold: settings.configuration.syncPreviewThresholdFiles
                    )
                    Text((reasons.map(\.sentence) + [String(localized: "Запуск ждёт подтверждения.")])
                        .joined(separator: " "))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Строка итога — то, чем источник закончил прошлый раз.
                Text(model.syncStatus(of: source.id).line)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)

                sourceAttentionRows(source, pending: pending, stale: stale)
            }
        }
    }

    /// Всё, что у источника требует решения или объяснения: пропавшие файлы,
    /// прежний экстрактор, ветка репозитория, исключённые пути.
    ///
    /// Каждая окрашенная строка — с действием рядом; строка без действия не
    /// красится (дизайн-система, раздел «Цвет»).
    @ViewBuilder
    private func sourceAttentionRows(
        _ source: DataSource, pending: [PendingRemoval], stale: [StaleExtraction]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Ядро приостанавливает автоматические режимы для источника,
            // чья прошлая синхронизация оборвалась и не доигралась.
            // Молча: расписание просто переставало срабатывать, и понять
            // почему было негде.
            if let reason = model.recoveryBlocks[source.id] {
                HStack(spacing: 8) {
                    Circle().fill(Theme.Palette.attention)
                        .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    Text("автоматическая индексация приостановлена: \(reason)")
                        .font(Theme.Font.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Синхронизировать вручную")) { model.sync(source, app: app) }
                        .buttonStyle(.chromaSecondary)
                        .disabled(model.isBusy(source.id) || !app.connection.isConnected)
                    Spacer()
                }
            }
            if !pending.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(Theme.Palette.attention)
                        .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    Text("файлы исчезли с диска: \(pending.count.plainDigits) — документы ждут вашего решения")
                        .font(Theme.Font.caption)
                    Spacer()
                }
            }
            // сказано, но не сделано. Переиндексация репозитория стоит
            // часов работы модели, и запускать её из-за переключения ветки
            // приложение не будет.
            if let note = model.gitStatus[source.id]?.branchChangeNote {
                Text(note)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.gitStatus[source.id], status.hasGit, !status.isRepository {
                Text("В этой папке нет git-репозитория — источник индексируется обычным обходом.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = model.gitStatus[source.id], !status.hasGit {
                Text("Git не установлен (`xcode-select --install`) — репозиторий индексируется как обычная папка.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // said, never done. An app update does not get to start hours
            // of local model time on its own — the line stays until the user
            // presses the button next to it.
            if !stale.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(Theme.Palette.attention)
                        .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    Text("извлечены прежней версией экстрактора: \(stale.count.plainDigits)")
                        .font(Theme.Font.caption)
                    Button(String(localized: "Переизвлечь и переэмбедить")) { model.reextract(source, app: app) }
                        .buttonStyle(.chromaSecondary)
                        .disabled(model.isBusy(source.id) || !app.connection.isConnected)
                    Spacer()
                }
                Text("Сначала делается бэкап. Ничего не пересчитывается, пока вы не нажмёте: \(Set(stale.map(\.previous.text)).sorted().joined(separator: ", ")) → \(stale.first?.current.text ?? "").")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // поля источника изменились, а в базе лежат прежние.
            // Не переиндексация: текст не менялся, менялись подписи к нему —
            // значит и модель звать незачем.
            if let count = model.outdatedMetadata[source.id], count > 0 {
                HStack(spacing: 8) {
                    Circle().fill(Theme.Palette.attention)
                        .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    Text("поля в базе записаны прежними настройками: \(count.plainDigits) файлов")
                        .font(Theme.Font.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Обновить поля")) { model.refreshMetadata(source, app: app) }
                        .buttonStyle(.chromaSecondary)
                        .disabled(model.isBusy(source.id) || !app.connection.isConnected)
                    Spacer()
                }
                Text("Переписываются только метаданные чанков: векторы не пересчитываются, модель не вызывается. Сначала делается бэкап.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // в папке появилась ещё одна ступень, и её смысл в базу
            // не попадает. Приложение не выдумывает ей имя и не делает работы
            // — говорит и ждёт, как и в
            if let level = (model.newFolderLevels[source.id] ?? []).first {
                HStack(spacing: 8) {
                    Circle().fill(Theme.Palette.attention)
                        .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    Text("появился уровень вложенности \(level.number.plainDigits): \(level.folderCount.plainDigits) папок (\(level.examples.joined(separator: ", ")))")
                        .font(Theme.Font.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Назвать уровень…")) { model.beginEditing(source) }
                        .buttonStyle(.chromaSecondary)
                        .disabled(model.isBusy(source.id))
                    Spacer()
                }
                Text("Пока поле не задано, названия этих папок в метаданные не пишутся. Уже проиндексированные файлы при этом не трогаются.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // an exclusion the user cannot see is a file that silently
            // stopped being indexed (rule 2 Приложения 5).
            ForEach(source.excludedPaths, id: \.self) { path in
                HStack(spacing: 6) {
                    Text("исключён: \(path)")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                    Button(String(localized: "вернуть")) { model.include(path, in: source, app: app) }
                        .font(Theme.Font.micro).buttonStyle(.link)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Правила запуска

    /// Настройки, влияющие на запуск, — рядом со списком, но свёрнуто: их
    /// трогают редко, а места они занимали столько же, сколько сам источник.
    /// Что стоит в умолчаниях нарезки — на экране источников, а не только
    /// в карточке одного из них.
    ///
    /// Правятся они по-прежнему **в карточке источника**: параметры
    /// настраивают там теми же полями, и второй редактор тех же двадцати
    /// значений разошёлся бы с первым — вопрос времени. Но у решения «править
    /// только там» была цена: человек, который ищет настройку, не находил её
    /// нигде. Здесь — ответ на вопрос «что сейчас задано и где это менять»,
    /// и единственное действие, которому в карточке источника не место:
    /// забыть всё разом.
    @ViewBuilder
    private var chunkingDefaultsSection: some View {
        let configuration = settings.configuration
        let own = ChunkStrategy.allCases.filter { configuration.hasOwnChunkingDefault(for: $0) }
        let strategy = configuration.defaultChunkingStrategy ?? ChunkingConfiguration().strategy

        AdvancedSection(
            place: "sources.chunkingDefaults",
            title: String(localized: "Умолчания нарезки")
        ) {
            Text("Новый источник заводится со стратегией «\(strategy.title)».")
                .font(Theme.Font.body)
                .fixedSize(horizontal: false, vertical: true)

            if own.isEmpty {
                Text("Своих значений не задано ни у одной стратегии — везде заводские.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // По строке на стратегию с её же сводкой: «свои умолчания
                // у трёх стратегий» не отвечает на вопрос, какие именно.
                ForEach(own) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.title).font(Theme.Font.caption).bold()
                            .frame(width: 150, alignment: .leading)
                        Text(configuration.chunkingDefault(for: item).summaryText)
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

            Text("Задаются и правятся в карточке источника — блок «Умолчания» под параметрами стратегии. Там же они и применяются: «Взять умолчание» подставляет их в открытый источник.")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

            if !own.isEmpty {
                HStack(spacing: 8) {
                    Button(String(localized: "Забыть все умолчания")) {
                        for item in own { settings.configuration.clearChunkingDefault(for: item) }
                        model.infoMessage = String(localized: "Умолчания сброшены к заводским у всех стратегий. Настройки заведённых источников не изменились.")
                    }
                    .buttonStyle(.chromaNormal)
                    Text("Заведённые источники это не тронет: у них свои значения.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    Spacer()
                }
            }
        }
    }

    private var launchRulesSection: some View {
        AdvancedSection(place: "sources.launch", title: String(localized: "Правила запуска")) {
            // below this, «Синхронизировать» just runs; above it, the plan is
            // shown first and has to be confirmed (rule 4, Приложение 5). Step of
            // 5, not 10: with 10 the small values were unreachable, and a
            // threshold you cannot set to 3 is not really tunable.
            Stepper(
                thresholdLabel,
                value: Binding(
                    get: { settings.configuration.syncPreviewThresholdFiles },
                    set: { settings.configuration.syncPreviewThresholdFiles = max(0, $0) }
                ),
                in: 0...10_000,
                step: 5
            )
            .font(Theme.Font.body)

            if settings.configuration.dataSources.contains(where: { $0.triggers.isAnyEnabled }) {
                Toggle(String(localized: "Приостановить всю автоматическую индексацию"), isOn: Binding(
                    get: { settings.configuration.automaticSyncPaused },
                    set: { autoSync.setPaused($0, app: app) }
                ))
                .font(Theme.Font.control)
                Text("На случай, когда LM Studio занята другой задачей. Ручная синхронизация продолжает работать.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Третий уровень текста — устройство раздела целиком, из макета.
    private var howItWorks: some View {
        HowItWorks(screen: "sources") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Папка → коллекция с инкрементальной синхронизацией: без изменений на диске повторный запуск не пересчитывает векторы. Изменение параметров нарезки — это новая нарезка: при следующей синхронизации все файлы источника будут перечанкованы и переэмбежены.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Удаления не выполняются автоматически ни в одном режиме: исчезнувшие файлы попадают в «Требуют решения». Таймеры живут, пока приложение запущено, — фоновых демонов приложение не устанавливает.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// An automatic run names its trigger, and a queued one says it is waiting:
    /// work happening without a visible reason is what the spec forbids.
    private func progressLabel(_ task: QueuedTaskInfo) -> String {
        let reason = model.activeReason?.isAutomatic == true
            ? " · \(model.activeReason?.title ?? "")"
            : ""
        guard task.state == .running else {
            return String(localized: "\(task.title) — в очереди\(reason)")
        }
        return "\(task.title)\(reason)"
    }

    /// Первая строка описания источника: чем он вообще является.
    private func sourceKindLine(_ source: DataSource) -> String {
        if source.isWeb { return "\(webSummary(source)) · \(source.chunking.summaryText)" }
        if let git = source.git {
            let scope = git.indexesWorkingCopy
                ? String(localized: "рабочая копия как есть")
                : String(localized: "только последний коммит")
            let branch = model.gitStatus[source.id]?.branch.map { String(localized: "ветка \($0)") }
                ?? String(localized: "git-репозиторий")
            return "\(branch), \(scope) · \(source.chunking.summaryText)"
        }
        return "\(source.mapping.title) · \(source.chunking.summaryText)"
    }

    /// Строка про веб-источник в списке: вид и то, чем он ограничен.
    private func webSummary(_ source: DataSource) -> String {
        guard let web = source.web else { return "" }
        switch web.kind {
        case .page:
            return String(localized: "одна страница")
        case .list:
            return String(localized: "список адресов: \((web.additionalURLs.count + 1).plainDigits)")
        case .site:
            let robots = web.respectsRobots
                ? String(localized: "robots.txt соблюдается")
                : String(localized: "robots.txt отключён")
            return String(localized: "обход сайта: глубина \(web.maxDepth.plainDigits), не больше \(web.maxPages.plainDigits) страниц, пауза \(Self.seconds(web.delaySeconds)) с, \(robots)")
        }
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func triggerText(_ source: DataSource) -> String {
        guard source.triggers.isAnyEnabled else { return String(localized: "запуск: только вручную") }
        if settings.configuration.automaticSyncPaused {
            return String(localized: "запуск: \(source.triggers.summary) — приостановлено")
        }
        if let next = autoSync.nextRun[source.id] {
            return String(localized: "запуск: \(source.triggers.summary) · следующий \(next.formatted(date: .omitted, time: .shortened))")
        }
        return String(localized: "запуск: \(source.triggers.summary)")
    }

    private func targetsText(_ source: DataSource, info: SourcesViewModel.ManifestInfo?) -> String {
        if let info, !info.collections.isEmpty {
            return "коллекции: \(info.collections.joined(separator: ", "))"
        }
        switch source.mapping {
        case .folderToCollection, .singleCollectionWithRelativePath:
            return "→ коллекция «\(source.collectionName)»"
        case .subfoldersToCollections:
            return "→ коллекции по подпапкам, файлы в корне — в «\(source.collectionName)»"
        case .manualRule:
            return "→ имя коллекции по правилу /\(source.rulePattern)/ → \(source.ruleTemplate)"
        }
    }

    // MARK: - Plan

    /// Планы в том же порядке, в каком идут источники: словарь отдаёт ключи
    /// как придётся, и карточки прыгали бы при каждом обновлении.
    private var orderedPlans: [SyncPlan] {
        settings.configuration.dataSources.compactMap { model.plans[$0.id] }
    }

    private func planCard(_ plan: SyncPlan) -> some View {
        let source = settings.configuration.dataSources.first { $0.id == plan.sourceID }
        let isPending = model.pendingConfirmations.contains(plan.sourceID)
        let includedWriteCount = plan.writeItems
            .filter { !model.isExcluded($0.relativePath, in: plan.sourceID) }
            .count

        return SectionCard(
            title: "План синхронизации «\(plan.sourceName)»",
            subtitle: "Сравнение папки с манифестом. Ничего не записано и не посчитано — это только предпросмотр."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if isPending {
                    // Текст — у самой причины. Прежде баннер всегда
                    // рассказывал про порог файлов, даже когда остановили
                    // ворота строк из таблиц: на плане из сорока двух файлов
                    // при пороге сто он писал «42 — больше порога 100».
                    let reasons = plan.confirmationReasons(
                        threshold: settings.configuration.syncPreviewThresholdFiles
                    )
                    MessageBanner(
                        kind: .warning,
                        text: (reasons.map(\.sentence)
                               + [String(localized: "Подтвердите запуск.")]).joined(separator: " ")
                    )
                }

                Text(plan.summaryLine).font(Theme.Font.body)
                if !plan.targetCollections.isEmpty {
                    Text("коллекции: \(plan.targetCollections.joined(separator: ", "))")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
                if let source {
                    let estimate = model.estimate(for: plan, source: source, app: app)
                    Text(estimateLine(chunks: estimate.chunks, time: estimate.time))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }

                let interesting = plan.items.filter { $0.kind != .unchanged }
                if interesting.isEmpty {
                    Text("Все файлы уже проиндексированы в текущей конфигурации.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                } else {
                    ForEach(interesting.prefix(40)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // Only a file that would actually be written needs a
                            // checkbox — skipped/unroutable/unchanged never
                            // reach the database either way.
                            if item.kind.writesDocuments {
                                Toggle("", isOn: Binding(
                                    get: { !model.isExcluded(item.relativePath, in: plan.sourceID) },
                                    set: { _ in model.toggleExcluded(item.relativePath, in: plan.sourceID) }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            }
                            Text(item.kind.title)
                                .font(Theme.Font.micro)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(kindColor(item.kind).opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                            Text(item.relativePath).font(Theme.Font.caption)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(model.isExcluded(item.relativePath, in: plan.sourceID) ? .secondary : .primary)
                            if let detail = item.kind.detail {
                                Text("— \(detail)").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            }
                            Spacer()
                            if let collection = item.collectionName, item.kind.writesDocuments {
                                Text(collection).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            }
                        }
                    }
                    if interesting.count > 40 {
                        Text("…и ещё \(interesting.count - 40)").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                }

                if let estimate = model.tableEstimates[plan.sourceID], estimate.needsConfirmation {
                    Label(
                        "Строк из таблиц: \(estimate.embeddings.plainDigits) — столько же обращений к модели. \(estimate.line).",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Пока идёт этот прогон, модель занята: другие запросы будут ждать. Имеет смысл сначала посмотреть на выборке, что получается из строк.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(isPending
                           ? String(localized: "Отменить")
                           : String(localized: "Скрыть план")) {
                        if isPending {
                            model.cancelPendingSync(plan.sourceID)
                        } else {
                            model.plans[plan.sourceID] = nil
                        }
                    }
                    .buttonStyle(.chromaNormal)

                    if let source, plan.hasWork {
                        Spacer()
                        // §​12.7: the offer to try the first rows stands next to
                        // the button that would spend hours of the model.
                        if let estimate = model.tableEstimates[plan.sourceID], estimate.needsConfirmation {
                            Stepper(
                                "строк в пробном прогоне: \(model.sampleRowCount.plainDigits)",
                                value: $model.sampleRowCount, in: 10...5_000, step: 50
                            )
                            .font(Theme.Font.caption)
                            Button(String(localized: "Попробовать на выборке")) { model.runSample(source, app: app) }
                                .buttonStyle(.chromaNormal)
                                .disabled(model.isBusy(source.id) || !app.connection.isConnected)
                        }
                        Button {
                            model.runPlannedSync(source, app: app)
                        } label: {
                            Text(includedWriteCount == plan.writeItems.count
                                 ? "Подтвердить и синхронизировать"
                                 : "Синхронизировать выбранное (\(includedWriteCount.plainDigits))")
                        }
                        .buttonStyle(.chromaPrimary)
                        .disabled(includedWriteCount == 0 || model.isBusy(source.id) || !app.connection.isConnected)
                    }
                }
            }
        }
    }

    /// Says what 0 actually does, instead of leaving «больше: 0» to be read as
    /// «выключено» — which is what it used to mean, wrongly.
    private var thresholdLabel: String {
        let value = settings.configuration.syncPreviewThresholdFiles
        guard value > 0 else {
            return String(localized: "Показывать план перед каждым ручным запуском")
        }
        return String(localized: "Показывать план перед запуском, если файлов больше: \(value.plainDigits)")
    }

    private func estimateLine(chunks: Int, time: SyncTimeEstimate?) -> String {
        guard chunks > 0 else { return "≈0 чанков" }
        guard let seconds = time?.totalSeconds, seconds > 0 else {
            return "≈\(chunks.plainDigits) чанков · оценка времени пока недоступна (нет прошлых прогонов этой стратегии или модели)"
        }
        return "≈\(chunks.plainDigits) чанков · \(Self.durationText(seconds))"
    }

    /// Carries its own «≈» so the sub-second case can be words instead of a
    /// number: «≈0 с» read as a placeholder rather than as «мгновенно».
    private static func durationText(_ seconds: Double) -> String {
        if seconds < 1 { return String(localized: "меньше секунды") }
        if seconds < 60 { return String(format: "≈%.0f с", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "≈%.0f мин", minutes) }
        return String(format: "≈%.1f ч", minutes / 60)
    }

    private func kindColor(_ kind: SyncItemKind) -> Color {
        switch kind {
        case .new: return .green
        case .changed: return .accentColor
        case .unchanged: return .secondary
        case .skipped, .unroutable: return .orange
        }
    }

    // MARK: - Summary

    private func summaryCard(_ summary: SyncSummary) -> some View {
        SectionCard(title: "Результат синхронизации «\(summary.sourceName)»") {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.line).font(Theme.Font.body)
                Text("модель: \(summary.embeddingModel)\(summary.dimension.map { " · размерность \($0)" } ?? "") · время \(SecondsText.line(summary.duration))")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                if !summary.collections.isEmpty {
                    Text("коллекции: \(summary.collections.joined(separator: ", "))")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
                if summary.wroteNothing {
                    Text("Изменений на диске не было — векторы не пересчитывались.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
                if !summary.markedForAttention.isEmpty {
                    Text("Помечено «требуют внимания» (схема не закрыта): \(summary.markedForAttention.count)")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                }
                if !summary.skipped.isEmpty {
                    Text("Пропущено файлов: \(summary.skipped.count)").font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    ForEach(Array(summary.skipped.prefix(10).enumerated()), id: \.offset) { _, item in
                        Text("• \(item.file) — \(item.reason)").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    if summary.skipped.count > 10 {
                        Text("…и ещё \(summary.skipped.count - 10)").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                }
                // Оговорки табличного конвейера: раньше они считались и
                // терялись по дороге. Файл, сохранённый без пересчёта
                // формул, индексировался пустыми значениями молча.
                if !summary.tableWarnings.isEmpty {
                    Text("Таблицы прочитаны с оговорками: \(summary.tableWarnings.count)")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    ForEach(Array(summary.tableWarnings.prefix(10).enumerated()), id: \.offset) { _, warning in
                        Text("• \(warning)").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    if summary.tableWarnings.count > 10 {
                        Text("…и ещё \(summary.tableWarnings.count - 10)").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                }
                if summary.tableRowsNeedingDecision > 0 {
                    Text("Строк таблиц исчезло из файлов: \(summary.tableRowsNeedingDecision.plainDigits) — ждут решения в «Требуют решения», из базы ничего не удалено")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Кнопки «Обновить список коллекций» здесь больше нет: она
                // обновляла список **другого** экрана, поэтому нажатие
                // выглядело так, будто ничего не произошло. Экран коллекций
                // теперь перечитывает список сам, как только прогон что-то
                // записал.
            }
        }
    }

    // MARK: - Pending decisions

    @ViewBuilder
    private var decisionsCard: some View {
        let pairs = settings.configuration.dataSources.compactMap { source -> (DataSource, [PendingRemoval])? in
            guard let removals = model.pendingRemovals[source.id], !removals.isEmpty else { return nil }
            return (source, removals)
        }

        let rowPairs = settings.configuration.dataSources.compactMap { source -> (DataSource, [PendingRowRemoval])? in
            guard let removals = model.pendingRowRemovals[source.id], !removals.isEmpty else { return nil }
            return (source, removals)
        }

        if !pairs.isEmpty || !rowPairs.isEmpty {
            SectionCard(
                title: "Требуют решения",
                subtitle: "Файлы и строки таблиц исчезли из источника. Документы остаются в базе, пока вы не решите иначе — автоматически приложение ничего не удаляет."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    // Разбор идёт файл за файлом и на девяноста файлах длится
                    // секунды. Без этой строки экран выглядел так, будто
                    // нажатие потеряли.
                    if let progress = model.resolveProgress {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                                .frame(width: 160)
                            Text(progress.text)
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            Spacer()
                        }
                    }
                    ForEach(pairs, id: \.0.id) { source, removals in
                        decisionGroup(source: source, removals: removals)
                    }
                    if !pairs.isEmpty && !rowPairs.isEmpty { Divider() }
                    ForEach(rowPairs, id: \.0.id) { source, removals in
                        rowDecisionGroup(source: source, removals: removals)
                    }
                }
            }
        }
    }

    /// Исчезнувшие строки таблиц одного источника.
    ///
    /// Решение принимается **о листе целиком**: строк там бывают тысячи, а
    /// вопрос к ним один — «это правка файла или сбой выгрузки». Разбирать их
    /// по одной значило бы просить о работе, которой не должно быть.
    private func rowDecisionGroup(source: DataSource, removals: [PendingRowRemoval]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(source.name) · строки таблиц").font(Theme.Font.control).bold()
            ForEach(removals) { removal in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(removal.relativePath) → \(removal.sheetName)")
                            .font(Theme.Font.caption)
                            .lineLimit(1).truncationMode(.middle)
                        Text("коллекция «\(removal.collectionName)» · строк \(removal.rows.count.plainDigits) · замечено \(removal.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        // Какие именно строки: без этого «исчезло 40» ничего
                        // не говорит о том, правка это или сбой выгрузки.
                        Text(removal.rowLabels.prefix(6).joined(separator: ", ")
                             + (removal.rows.count > 6 ? String(localized: "…и ещё \(removal.rows.count - 6)") : ""))
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(String(localized: "Оставить в базе")) {
                        model.resolveRows([removal], decision: .keepInDatabase, source: source, app: app)
                    }
                    .buttonStyle(.chromaNormal)
                    .disabled(model.resolveProgress != nil)
                    Button(String(localized: "Удалить из базы")) {
                        model.resolveRows([removal], decision: .deleteChunks, source: source, app: app)
                    }
                    .buttonStyle(.chromaDanger)
                    .disabled(!app.connection.isConnected || model.resolveProgress != nil)
                }
            }
        }
    }

    /// Исчезнувшие файлы одного источника: выбор строками и одно решение
    /// на всё выбранное. Их бывает шесть десятков, и нажимать по
    /// каждой строке отдельно — работа, которой не должно быть.
    private func decisionGroup(source: DataSource, removals: [PendingRemoval]) -> some View {
        let chosen = removals.filter { selectedRemovals.contains(key(source, $0)) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(source.name).font(Theme.Font.control).bold()
                Button(chosen.count == removals.count
                       ? String(localized: "Снять выбор")
                       : String(localized: "Выбрать все")) {
                    let keys = removals.map { key(source, $0) }
                    if chosen.count == removals.count {
                        selectedRemovals.subtract(keys)
                    } else {
                        selectedRemovals.formUnion(keys)
                    }
                }
                .buttonStyle(.link).font(Theme.Font.micro)
                Spacer()
                if !chosen.isEmpty {
                    Text("выбрано \(chosen.count.plainDigits) из \(removals.count.plainDigits)")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    Button(String(localized: "Оставить в базе")) {
                        model.resolve(chosen, decision: .keepInDatabase, source: source, app: app)
                        selectedRemovals.subtract(chosen.map { key(source, $0) })
                    }
                    .buttonStyle(.chromaNormal)
                    .disabled(model.resolveProgress != nil)
                    Button(String(localized: "Удалить из базы")) {
                        model.resolve(chosen, decision: .deleteChunks, source: source, app: app)
                        selectedRemovals.subtract(chosen.map { key(source, $0) })
                    }
                    .buttonStyle(.chromaDanger)
                    .disabled(!app.connection.isConnected || model.resolveProgress != nil)
                }
            }
            // Строк столько же, сколько исчезло файлов, а исчезнуть может
            // папка целиком. Каждая строка — флажок, две кнопки и два текста;
            // восемьсот таких строк раскладываются секундами и роняют
            // интерфейс. «Выбрать все» по-прежнему выбирает все,
            // а не только показанные: решение принимается обо всём наборе.
            ForEach(removals.prefix(removalLimit)) { removal in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { selectedRemovals.contains(key(source, removal)) },
                        set: { isOn in
                            if isOn {
                                selectedRemovals.insert(key(source, removal))
                            } else {
                                selectedRemovals.remove(key(source, removal))
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(removal.relativePath).font(Theme.Font.caption)
                            .lineLimit(1).truncationMode(.middle)
                        Text("коллекция «\(removal.collectionName)» · чанков \(removal.chunkIDs.count) · замечено \(removal.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer(minLength: 8)
                    // Действия по одной строке остаются: разобрать один файл —
                    // самый частый случай, и выделять его ради этого незачем.
                    Button(String(localized: "Оставить в базе")) {
                        model.resolve([removal], decision: .keepInDatabase, source: source, app: app)
                    }
                    .buttonStyle(.chromaNormal)
                    .disabled(model.resolveProgress != nil)
                    Button(String(localized: "Удалить из базы")) {
                        model.resolve([removal], decision: .deleteChunks, source: source, app: app)
                    }
                    .buttonStyle(.chromaDanger)
                    .disabled(!app.connection.isConnected || model.resolveProgress != nil)
                }
            }
            if removals.count > removalLimit {
                HStack(spacing: 8) {
                    Text("показаны первые \(removalLimit.plainDigits) из \(removals.count.plainDigits)")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    Button(String(localized: "Показать ещё 50")) { removalLimit += 50 }
                        .buttonStyle(.chromaSecondary)
                    Spacer()
                }
            }
        }
    }

    private func key(_ source: DataSource, _ removal: PendingRemoval) -> String {
        "\(source.id.uuidString)|\(removal.relativePath)"
    }
}

// MARK: - Editor

/// Everything about one source in one sheet: mapping, extensions, chunking
/// parameters and the hookup with the target collection's schema.
struct SourceEditorSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var schemaStore: SchemaStore
    @ObservedObject var model: SourcesViewModel
    @ObservedObject var embeddings: EmbeddingsViewModel

    @State private var coverage: SourceSchemaCoverage?
    /// Что случилось после нажатия в карточке схемы. Раньше ответ уходил в
    /// `infoMessage` экрана источников — то есть **за лист**, и кнопка со
    /// стороны выглядела нерабочей.
    @State private var schemaNotice: String?
    /// Ответ кнопок умолчаний нарезки — по той же причине здесь, а не
    /// в `infoMessage`: сообщение экрана источников уходит **за лист**.
    @State private var chunkingNotice: String?
    /// Измеренный предел чтения модели этого источника.
    @State private var inputLimit: Int?
    @State private var isMeasuringLimit = false
    @State private var limitMeasured = false
    /// Проба сорвалась. Отдельно от «предела не нашлось»: это
    /// противоположные ответы, и путать их значит говорить «модель читает
    /// сколько угодно» там, где на самом деле не удалось спросить.
    @State private var limitProbeFailed = false
    @State private var showExtendedGeneration = false

    /// asked once per chat model and remembered, so the indicator can say
    /// which mode a run will actually use before it starts.
    enum StructuredOutputSupport { case unknown, waiting, checking, supported, unsupported }
    @State private var structuredOutputSupport: StructuredOutputSupport = .unknown

    var body: some View {
        SheetShell(
            title: model.draftIsNew
                ? String(localized: "Новый источник")
                : String(localized: "Настройка источника"),
            subtitle: String(localized: "Файлы источника разрезаются на чанки и попадают в коллекцию. Ничего не индексируется, пока источник не синхронизирован."),
            help: String(localized: "Источник — это папка, сайт или репозиторий, за которым приложение следит. Настройки ниже описывают, что из него читать, куда класть, как резать и когда обновлять. Изменение размеров чанков или модели у уже проиндексированного источника означает пересчёт всех его файлов при следующей синхронизации.")
        ) {
            if model.draft != nil {
                if model.draft?.isWeb == true {
                    webBasics
                } else {
                    if model.draft?.isGit == true { gitBasics }
                    basics
                    mapping
                    pathLevels
                }
                chunking
                triggers
                metadata
                schemaHookup
            }
        } actions: {
            if let problem = ruleProblem ?? model.pathLevelProblem {
                Text(problem)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "Отмена")) { model.cancelDraft() }
                .buttonStyle(.chromaNormal)
            Button(model.draftIsNew
                   ? String(localized: "Добавить")
                   : String(localized: "Сохранить")) { model.saveDraft(app) }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(ruleProblem != nil || model.pathLevelProblem != nil)
        }
        .task(id: model.draft?.id) {
            model.scanDraftLevels(app)
            await refreshCoverage()
            showExtendedGeneration = model.draft?.chunking.generation.usesExtendedBlockValues ?? false
        }
        .task(id: model.draft?.chunking.chatModel) { await refreshStructuredOutputSupport() }
        // Поля из пути — такая же часть договора с коллекцией, как ручные:
        // изменили уровень — карточка схемы обязана ответить сразу.
        .task(id: model.draft?.metadataSignature) { await refreshCoverage() }
    }

    /// Probes the chosen chat model once. Only for LLM-based chunking: no other
    /// strategy calls a chat model, so asking would load one for nothing.
    ///
    /// **Через очередь, и последней в ней**. Проба — это запрос к чужой
    /// модели: LM Studio грузит её тут же, а занятую выгружает, и идущая
    /// индексация падает с «Model was unloaded while the request was still in
    /// queue». Настройка источника ничего не индексирует, поэтому и права
    /// прервать индексацию у неё нет: очередь держит группу «локальная модель»
    /// строго последовательной, а `.background` ставит пробу за всем, что уже
    /// начато. Пока она ждёт, форма так и говорит.
    private func refreshStructuredOutputSupport() async {
        guard let draft = model.draft, draft.chunking.strategy == .llmBased,
              let chatModel = draft.chunking.chatModel, !chatModel.isEmpty else {
            structuredOutputSupport = .unknown
            return
        }
        guard let lmStudio = try? app.makeLMStudioClient() else {
            structuredOutputSupport = .unknown
            return
        }
        structuredOutputSupport = await app.queue.isRunning(group: .lmStudio) ? .waiting : .checking
        let ticket = QueueTicket(
            title: String(localized: "Проверка модели «\(chatModel)»"),
            priority: .background,
            group: .lmStudio,
            connectionID: app.connectionID
        )
        // Закрыли лист — задача вида отменяется, и ожидание в очереди вместе
        // с ней: держать очередь ради ответа, который некому показать, незачем.
        let probe: Bool?
        do {
            probe = try await app.queue.run(ticket) { _ in
                await lmStudio.supportsStructuredOutput(model: chatModel)
            }
        } catch {
            probe = nil
        }
        guard let supported = probe else {
            structuredOutputSupport = .unknown
            return
        }
        structuredOutputSupport = supported ? .supported : .unsupported
    }

    /// The draft being edited, as a non-optional binding the fields can use.
    ///
    /// The setter refuses to write when there is no draft any more, and that
    /// guard is the whole point. Saving sets `model.draft` to `nil`, and the
    /// sheet starts to go away — but a field still on screen commits its value
    /// on the way out. Without the guard that write goes through `get`, which
    /// hands back a **brand-new empty** `DataSource`, and stores it: the draft
    /// comes back from the dead, `draft != nil` is true again, and the editor
    /// reopens on an empty form right after a source was added successfully.
    /// Languages this machine can recognise — asked of Vision, never hardcoded:
    /// the list differs between macOS versions.
    private var ocrLanguages: some View {
        let supported = VisionOCRExtractor.supportedLanguages()
        return VStack(alignment: .leading, spacing: 6) {
            if supported.isEmpty {
                Text("Система не сообщила ни одного языка распознавания — распознавание работать не будет.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
            } else {
                Text("Языки распознавания (\(supported.count) доступно на этой системе)")
                    .font(Theme.Font.caption)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(supported, id: \.self) { language in
                        Toggle(language, isOn: Binding(
                            get: { draft.wrappedValue.ocrLanguages.contains(language) },
                            set: { isOn in
                                var languages = Set(draft.wrappedValue.ocrLanguages)
                                if isOn { languages.insert(language) } else { languages.remove(language) }
                                draft.wrappedValue.ocrLanguages = languages.sorted()
                            }
                        ))
                        .font(Theme.Font.micro)
                        .toggleStyle(.checkbox)
                    }
                }
                Text("Ничего не выбрано — Vision выберет сам. Выбор нескольких языков замедляет распознавание.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
        .padding(.leading, 16)
    }

    private var draft: Binding<DataSource> {
        Binding(
            get: { model.draft ?? DataSource(name: "", path: "", collectionName: "") },
            set: { updated in
                guard model.draft != nil else { return }
                model.draft = updated
            }
        )
    }

    private var ruleProblem: String? {
        guard let source = model.draft, source.mapping.needsRule else { return nil }
        return CollectionRouter.ruleProblem(pattern: source.rulePattern, template: source.ruleTemplate)
    }

    // MARK: Sections

    /// Настройка git-репозитория. Идёт **над** общими настройками папки:
    /// расширения, OCR и остальное репозиторию нужны ровно так же, разница
    /// только в том, кто составляет список файлов.
    private var gitBasics: some View {
        let git = Binding(
            get: { draft.wrappedValue.git ?? GitSourceSettings() },
            set: { draft.wrappedValue.git = $0 }
        )
        return SectionCard(
            title: String(localized: "Репозиторий"),
            subtitle: String(localized: "Список файлов даёт git, а не обход папки."),
            help: String(localized: "В индекс не попадут ни .git, ни то, что перечислено в .gitignore, а что изменилось с прошлого раза, скажет один вызов вместо десятков тысяч чтений. Маски исключений действуют поверх .gitignore, а не вместо него. Подмодули не обходятся: их файлы принадлежат другому репозиторию.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                Picker(String(localized: "Индексировать"), selection: git.indexesWorkingCopy) {
                    Text("рабочую копию как есть").tag(true)
                    Text("только последний коммит").tag(false)
                }
                .pickerStyle(.radioGroup)
                .font(Theme.Font.control)
                Text("«Как есть» берёт и незакоммиченные правки — обычно этого и хотят. «Только последний коммит» кладёт в базу ровно то, что видят остальные.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)

                readingOption(
                    String(localized: "Записывать автора и дату последнего коммита"),
                    note: String(localized: "Добавит last_commit_author и last_commit_date. Это отдельный вызов git на каждый файл."),
                    isOn: git.includesCommitInfo
                )

                TextField(String(localized: "Исключения масками через запятую (*.lock, vendor/*)"), text: Binding(
                    get: { git.wrappedValue.excludedGlobs.joined(separator: ", ") },
                    set: { git.wrappedValue.excludedGlobs = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// Настройка веб-источника.
    private var webBasics: some View {
        let web = Binding(
            get: { draft.wrappedValue.web ?? WebSourceSettings() },
            set: { draft.wrappedValue.web = $0 }
        )
        return Group {
            SectionCard(
                title: String(localized: "Адрес и обход"),
                subtitle: web.wrappedValue.kind.explanation,
                help: String(localized: "Ограничения обхода обязательны все четыре: без них источник превращается в неуправляемого краулера. Когда одно из них срабатывает, обход останавливается и говорит об этом в сводке — молча закончиться он не может. Карта сайта полнее обхода по ссылкам: страницу, на которую нет ссылок с главной, по ссылкам не найти; когда карта нашлась, по ссылкам приложение не ходит вовсе. По умолчанию обход не выходит за пределы исходного домена, www. считается тем же сайтом.")
            ) {
                VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                    TextField(String(localized: "Имя источника"), text: draft.name)
                        .textFieldStyle(.roundedBorder)

                    Picker(String(localized: "Вид источника"), selection: web.kind) {
                        ForEach(WebSourceSettings.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    TextField("https://example.org/страница", text: web.startURL)
                        .textFieldStyle(.roundedBorder)
                    if let problem = web.wrappedValue.problem {
                        Text(problem).font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    }

                    if web.wrappedValue.kind == .list {
                        Text("Остальные адреса, по одному в строке")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        TextEditor(text: Binding(
                            get: { web.wrappedValue.additionalURLs.joined(separator: "\n") },
                            set: { web.wrappedValue.additionalURLs = $0.components(separatedBy: .newlines) }
                        ))
                        .font(Theme.Font.mono)
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.field)
                                .strokeBorder(Theme.Palette.border, lineWidth: 1)
                        )
                    }

                    if web.wrappedValue.kind == .site {
                        HStack(spacing: 16) {
                            Stepper("Глубина: \(web.wrappedValue.maxDepth.plainDigits)", value: web.maxDepth, in: 0...10)
                            Stepper("Не больше страниц: \(web.wrappedValue.maxPages.plainDigits)", value: web.maxPages, in: 1...5000, step: 10)
                        }
                        HStack(spacing: 16) {
                            Stepper("Пауза между запросами: \(SourcesSection.seconds(web.wrappedValue.delaySeconds)) с", value: web.delaySeconds, in: 0...60, step: 0.5)
                            Stepper("Не больше \(web.wrappedValue.maxTotalMegabytes.plainDigits) МБ", value: web.maxTotalMegabytes, in: 1...5000, step: 50)
                        }

                        Toggle(String(localized: "Использовать карту сайта (sitemap.xml)"), isOn: web.usesSitemap)
                            .font(Theme.Font.control)

                        TextField(String(localized: "Другие разрешённые домены через запятую"), text: Binding(
                            get: { web.wrappedValue.extraHosts.joined(separator: ", ") },
                            set: { web.wrappedValue.extraHosts = $0.split(separator: ",").map { String($0) } }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    Toggle(String(localized: "Соблюдать robots.txt"), isOn: web.respectsRobots)
                        .font(Theme.Font.control)
                    // Исключение сильнее правила: обращение наружу от вашего
                    // имени остаётся на экране целиком, а не под «?».
                    if !web.wrappedValue.respectsRobots {
                        Text("robots.txt — это то, о чём сайт просит прямо. Отключайте только для собственных доменов: на чужом сервере это чужие правила, и нарушать их приложение будет вашим именем. Отключение записывается в журнал при каждом запуске.")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SectionCard(
                title: String(localized: "Куда попадают страницы"),
                subtitle: String(localized: "Все страницы источника идут в одну коллекцию: у страницы нет папки, по которой её можно было бы разложить."),
                help: String(localized: "Адрес, время загрузки, код ответа и content_type пишутся в каждый чанк всегда — без них нельзя понять, откуда он взялся. Смена модели у уже проиндексированного источника пересчитает все его страницы.")
            ) {
                VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                    TextField(String(localized: "Коллекция"), text: draft.collectionName)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Text("Модель эмбеддинга").font(Theme.Font.control)
                        Picker("", selection: Binding(
                            get: { draft.wrappedValue.embeddingModel ?? "" },
                            set: { draft.wrappedValue.embeddingModel = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("по умолчанию (\(settings.configuration.defaultEmbeddingModel ?? "не выбрана"))").tag("")
                            ForEach(embeddings.embeddingModels) { item in
                                Text(item.id).tag(item.id)
                            }
                        }
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }

                    readingOption(
                        String(localized: "Извлекать метаданные документа"),
                        note: String(localized: "Заголовок и язык страницы — в метаданные каждого чанка."),
                        isOn: draft.includeDocumentMetadata
                    )
                }
            }
        }
    }

    /// Что читать из папки. Перечень форматов и оговорки про автоматизацию
    /// уехали под «?»: между полями им было по десять строк на каждое.
    private var basics: some View {
        SectionCard(
            title: String(localized: "Папка и файлы"),
            subtitle: String(localized: "Имя источника и то, какие файлы из папки читать."),
            help: String(localized: "Читаются напрямую: текст, Markdown, код, JSON и XML. HTML — своим разбором: скрипты, стили и меню выбрасываются, заголовки h1–h6 становятся структурой. PDF — через PDFKit, нужен текстовый слой. Word, RTF и OpenDocument — средствами системы: таблицы приводятся к тексту, комментарии и сноски не извлекаются. EPUB — по оглавлению книги; книга с DRM попадает в «требуют решения». Таблицы (.xlsx, .xlsm, .ods, .csv, .tsv) идут своим путём: строка становится отдельным документом по профилю сопоставления, который настраивается кнопкой «Таблицы». Двоичный .xlsb и презентации пока не поддерживаются.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                TextField(String(localized: "Имя источника"), text: draft.name)
                    .textFieldStyle(.roundedBorder)
                Text(draft.wrappedValue.path)
                    .font(Theme.Font.mono).foregroundStyle(Theme.Palette.captionText)
                    .lineLimit(2).truncationMode(.middle)

                HStack(spacing: 10) {
                    TextField(String(localized: "Расширения через запятую"), text: Binding(
                        get: { draft.wrappedValue.fileExtensions.joined(separator: ", ") },
                        set: { text in
                            draft.wrappedValue.fileExtensions = text
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
                                .filter { !$0.isEmpty }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    // Сузить список — одно движение, а собрать его обратно по
                    // памяти нельзя: пусть возврат к полному стоит одно нажатие.
                    Button(String(localized: "Все поддерживаемые")) {
                        draft.wrappedValue.fileExtensions = TextExtractor.supportedExtensions
                    }
                    .buttonStyle(.chromaSecondary)
                    .disabled(draft.wrappedValue.fileExtensions == TextExtractor.supportedExtensions)
                    Toggle(String(localized: "Рекурсивно"), isOn: draft.recursive)
                        .font(Theme.Font.control)
                }

                Divider()

                HStack(spacing: 8) {
                    Stepper(
                        String(localized: "Не читать файлы больше \(draft.wrappedValue.maxFileSizeMB) МБ"),
                        value: draft.maxFileSizeMB, in: 1...500, step: 5
                    )
                    .frame(maxWidth: 340)
                }
                .font(Theme.Font.control)
                Text("Пропущенные по размеру видны в списке «Пропущено файлов» после прогона.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                readingOption(
                    String(localized: "Распознавать сканированные документы (OCR)"),
                    note: String(localized: "Для PDF без текстового слоя. На порядок медленнее: папка из тысячи файлов — часы."),
                    isOn: draft.ocrEnabled
                )
                if draft.wrappedValue.ocrEnabled { ocrLanguages }
                // Предупреждение показывается только тем, кого оно касается:
                // структуру используют две стратегии из шести, и раньше
                // подменялись все, а узнать об этом можно было лишь раскрыв
                // чанк.
                if draft.wrappedValue.ocrEnabled,
                   [.documentBased, .hierarchical].contains(draft.wrappedValue.chunking.strategy) {
                    Label(
                        String(localized: "У распознанных страниц нет структуры, поэтому «\(draft.wrappedValue.chunking.strategy.title)» к ним не применится — они будут нарезаны Recursive. Остальные стратегии структуру не используют и работают как выбраны."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(Theme.Font.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                readingOption(
                    String(localized: "Читать Pages и Keynote через экспорт"),
                    note: String(localized: "Поднимает окно программы, и macOS один раз спросит разрешение на автоматизацию."),
                    isOn: draft.iWorkExportEnabled
                )
                if draft.wrappedValue.iWorkExportEnabled {
                    Toggle(String(localized: "Разрешить и при автоматической синхронизации"), isOn: draft.iWorkExportInAutomaticRuns)
                        .font(Theme.Font.control)
                        .padding(.leading, 18)
                    Text("Иначе индексация по расписанию начнёт открывать окна Pages, пока вы работаете.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }

                // Флаг существовал в модели с, но переключателя у него не
                // было — то есть путь через Numbers был выключен навсегда, и
                // .numbers молча падали в «требуют решения» с причиной «экспорт
                // выключен в настройках источника», которую негде было включить.
                readingOption(
                    String(localized: "Читать .numbers и .xls через Numbers"),
                    note: String(localized: "Те же условия, что у Pages, и при автоматической синхронизации не работает никогда."),
                    isOn: draft.numbersExportEnabled
                )

                readingOption(
                    String(localized: "Извлекать метаданные документа"),
                    note: String(localized: "document_title, document_author, document_language и document_created — в каждый чанк."),
                    isOn: draft.includeDocumentMetadata
                )
            }
        }
    }

    /// Переключатель чтения и одна строка о следствии — не абзац.
    private func readingOption(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn).font(Theme.Font.control)
            Text(note)
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
        }
    }

    private var mapping: some View {
        SectionCard(
            title: String(localized: "Куда попадают файлы"),
            subtitle: String(localized: "Коллекция, которую наполняет этот источник, и чем считаются её векторы."),
            help: String(localized: "Одна папка может наполнять одну коллекцию, по коллекции на подпапку или коллекции по правилу из пути. Метрика действует только на коллекции, которых ещё нет: у существующей её изменить нельзя. Смена модели эмбеддинга у уже проиндексированного источника пересчитает все его файлы — векторы разных моделей несравнимы.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
            Picker(String(localized: "Режим маппинга"), selection: draft.mapping) {
                ForEach(SourceMapping.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text(draft.wrappedValue.mapping.summary)
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text(draft.wrappedValue.mapping == .subfoldersToCollections
                     ? String(localized: "Коллекция для файлов в корне")
                     : String(localized: "Коллекция"))
                    .font(Theme.Font.control)
                TextField(String(localized: "имя коллекции"), text: draft.collectionName)
                    .textFieldStyle(.roundedBorder)
            }
            if let problem = CollectionNaming.firstProblem(with: draft.wrappedValue.collectionName) {
                Text("\(problem) Имя будет приведено к «\(CollectionNaming.sanitize(draft.wrappedValue.collectionName))».")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Метрика новых коллекций").font(Theme.Font.control)
                Picker("", selection: draft.metric) {
                    ForEach(DistanceMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text("Модель эмбеддинга").font(Theme.Font.control)
                Picker("", selection: Binding(
                    get: { draft.wrappedValue.embeddingModel ?? "" },
                    set: { draft.wrappedValue.embeddingModel = $0.isEmpty ? nil : $0 }
                )) {
                    Text("по умолчанию (\(settings.configuration.defaultEmbeddingModel ?? "не выбрана"))").tag("")
                    ForEach(embeddings.embeddingModels) { item in
                        Text(item.id).tag(item.id)
                    }
                }
                .labelsHidden()
                Spacer(minLength: 0)
            }

            if draft.wrappedValue.mapping.needsRule {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(String(localized: "Регулярное выражение по относительному пути"), text: draft.rulePattern)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.mono)
                    TextField(String(localized: "Шаблон имени коллекции ($1, $2…)"), text: draft.ruleTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.mono)
                    Toggle(String(localized: "Файлы, не подошедшие под правило, — в коллекцию по умолчанию"), isOn: draft.ruleUsesFallbackCollection)
                        .font(Theme.Font.control)
                    Text("Например: выражение `^([^/]+)/` и шаблон `$1` дадут имя коллекции по первой папке пути.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Padding.rowHorizontal)
                .background(Theme.Palette.subtleFill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.row)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
            }
            }
        }
    }

    /// Уровни вложенности как поля метаданных.
    ///
    /// Отдельным блоком, а не пятым режимом маппинга: режим отвечает на вопрос
    /// «в какую коллекцию», уровни — «что известно о файле из его места
    /// в дереве». Пустой блок ничего не меняет, и источник ведёт себя ровно
    /// как прежде.
    @ViewBuilder
    private var pathLevels: some View {
        SectionCard(
            title: String(localized: "Поля из пути"),
            subtitle: String(localized: "Названия папок становятся полями каждого чанка — по ним потом фильтруют выдачу."),
            help: String(localized: "Уровень — это папка на своей глубине: первый уровень внутри папки источника, второй внутри него и так далее. Имя поля пишется латиницей: по нему фильтруют запросы и ходят внешние клиенты. Значение берётся с папки как есть — хоть кириллицей, хоть с пробелами. Уровень без имени не пишется никуда. Изменение полей не пересчитывает векторы: их можно обновить отдельной операцией.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                if model.draftLevelsScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Считаем уровни папки…").font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                    }
                } else if let problem = model.draftLevelsProblem {
                    Text("Папку прочитать не удалось: \(problem)")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let levels = model.draftFolderLevels, levels.isEmpty,
                          draft.wrappedValue.pathLevels.isEmpty {
                    Text("Внутри папки нет подпапок с подходящими файлами — полям из пути неоткуда взяться.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(draft.pathLevels.enumerated()), id: \.element.id) { index, level in
                    pathLevelRow(index: index, level: level)
                }

                if let levels = model.draftFolderLevels, levels.deeperThanLimit {
                    Text("В папке есть пути глубже \(PathLevel.maximumLevels.plainDigits) уровней — их названия полями не станут.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !draft.wrappedValue.pathLevels.filter(\.isNamed).isEmpty {
                    pathLevelPreview
                }
            }
        }
    }

    /// Одна строка уровня: что в нём лежит, как назвать и что писать файлам,
    /// которые до него не достают.
    @ViewBuilder
    private func pathLevelRow(index: Int, level: Binding<PathLevel>) -> some View {
        let known = model.draftFolderLevels?.levels.first { $0.number == index + 1 }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Уровень \((index + 1).plainDigits)")
                    .font(Theme.Font.control)
                    .frame(width: 90, alignment: .leading)
                TextField(String(localized: "имя поля (латиницей)"), text: level.key)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .frame(maxWidth: 200)
                Picker("", selection: level.type) {
                    ForEach(MetadataFieldType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                TextField(String(localized: "если папки нет"), text: level.fallbackValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                Spacer(minLength: 0)
            }
            if let known {
                Text("\(known.folderCount.plainDigits) папок: \(known.examples.joined(separator: ", "))\(known.folderCount > known.examples.count ? "…" : "")")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .lineLimit(1).truncationMode(.tail)
            }
            if let problem = PathLevel.keyProblem(level.wrappedValue.key) {
                Text(problem)
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if level.wrappedValue.isNamed, let known {
                // Две вещи, о которых честнее сказать до прогона: сколько файлов
                // останутся без поля и сколько папок не приводятся к типу.
                if known.filesAbove > 0 {
                    Text("\(known.filesAbove.plainDigits) файлов лежат выше этого уровня\(level.wrappedValue.fallbackValue.isEmpty ? " — у них поля не будет" : " — им запишется «\(level.wrappedValue.fallbackValue)»").")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let mismatched = known.namesNotMatching(level.wrappedValue)
                if !mismatched.isEmpty {
                    Text("Не разбираются как \(level.wrappedValue.type.title): \(mismatched.prefix(3).joined(separator: ", "))\(mismatched.count > 3 ? "…" : "") — \(mismatched.count.plainDigits) из \(known.names.count.plainDigits). Таким файлам поле не запишется.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Предпросмотр на настоящих путях: показать результат на выдуманном
    /// `folder/file.txt` значит показать не то.
    @ViewBuilder
    private var pathLevelPreview: some View {
        let source = draft.wrappedValue
        let samples = model.draftFolderLevels?.samplePaths ?? []
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Так это запишется:").font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.captionText)
                ForEach(samples, id: \.self) { path in
                    let fields = CollectionRouter.levelFields(for: path, levels: source.pathLevels)
                    Text("\(path) → \(fields.isEmpty ? String(localized: "полей нет") : fields.keys.sorted().map { "\($0)=\(fields[$0]?.displayString ?? "")" }.joined(separator: ", "))")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var chunking: some View {
        SectionCard(
            title: String(localized: "Как резать на чанки"),
            subtitle: draft.wrappedValue.chunking.strategy.summary,
            // Исключение сильнее правила: пересчёт векторов не прячется
            // под «?» — он остаётся строкой на экране, ниже.
            help: String(localized: "Стратегия определяет, где проходят границы чанков: по размеру, по структуре документа, по смыслу или моделью. Рекомендация под выбором — о том, для каких документов эта стратегия задумана. Токены считаются приблизительно: LM Studio не отдаёт токенайзер модели через API.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
            Picker(String(localized: "Стратегия"), selection: draft.chunking.strategy) {
                ForEach(ChunkStrategy.allCases) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            .font(Theme.Font.control)

            Text(draft.wrappedValue.chunking.strategy.recommendation).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = draft.wrappedValue.chunking.strategy.costWarning {
                // Said before the run, not after it.
                Text(warning).font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only the parameters of the chosen strategy are shown.
            Group {
                switch draft.wrappedValue.chunking.strategy {
                case .fixed:
                    sizeAndOverlap
                case .recursive:
                    sizeAndOverlap
                    separatorsField
                case .documentBased:
                    documentBasedParameters
                case .hierarchical:
                    hierarchicalParameters
                case .semantic:
                    semanticParameters
                case .adaptive:
                    adaptiveParameters
                case .llmBased:
                    llmParameters
                }
            }

            // контекст в вектор. Здесь, а не в параметрах стратегии:
            // работает при любой из них и меняет содержимое коллекции,
            // то есть требует переиндексации — о чём и сказано.
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: draft.chunking.contextPrefix) {
                    Text("Дописывать контекст перед вычислением вектора")
                }
                .toggleStyle(.checkbox)
                Text("Перед текстом чанка в модель уходит строка «Документ → Раздел → Подраздел». В самом документе её нет — он остаётся таким, как в файле. Чанк «превышение допустимого значения приводит к отказу» без этой строки не находится ничем: в нём нет ни одного слова о том, о чём он.\n\nСюда же попадает вводная фраза списка — та, что кончается двоеточием. Пункт «восстановление работоспособности в течение четырёх часов» без неё не говорит, чего восстановление и кто обязан: это стояло строкой выше, в «Исполнитель обязан обеспечить:».")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                if draft.wrappedValue.chunking.contextPrefix {
                    Label("Это меняет содержимое коллекции: при следующей синхронизации все файлы источника будут переэмбежены.", systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // то же самое, но словами чат-модели — и по вызову на чанк.
            // Цена стоит рядом с переключателем, а не в справке: включают её
            // один раз, а платят часами работы модели.
            Divider()
            enrichmentRow

            if let problem = draft.wrappedValue.chunking.problem {
                Text(problem).font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            modelReadingLimit

            Divider()
            chunkingDefaults

            Text("Изменение параметров — это новая нарезка: при следующей синхронизации все файлы источника будут перечанкованы и переэмбежены.")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Умолчания подставляются при переключении стратегии — и только
        // у нового источника. У заведённого числа его собственные.
        .onChange(of: draft.wrappedValue.chunking.strategy) { _, strategy in
            model.chunkingStrategyChanged(to: strategy, app: app)
        }
    }

    /// Контекстное обогащение чат-моделью.
    ///
    /// Правило приложения 5 в самой прямой форме: операция, которая займёт
    /// часы, обязана назвать свою цену **до** запуска. Поэтому под
    /// переключателем стоит не описание пользы, а число вызовов и время —
    /// и время не выдумывается: без замера скорости модели его нет вовсе.
    @ViewBuilder
    private var enrichmentRow: some View {
        let chunking = draft.wrappedValue.chunking
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: draft.chunking.contextEnrichment) {
                Text("Обогащать контекст чат-моделью")
            }
            .toggleStyle(.checkbox)
            Text("Модель читает фрагмент и пишет одно-два предложения о том, о чём документ и где в нём этот фрагмент. Они уходят в вектор — в документе их нет. Заметно помогает там, где заголовков нет и структурная строка молчит.")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

            if chunking.contextEnrichment {
                Picker(String(localized: "Модель обогащения"), selection: Binding(
                    get: { chunking.resolvedEnrichmentModel ?? "" },
                    set: { draft.wrappedValue.chunking.enrichmentModel = $0.isEmpty ? nil : $0 }
                )) {
                    Text("не выбрана").tag("")
                    ForEach(chatModelOptions, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .font(Theme.Font.control)

                Label(enrichmentCostLine, systemImage: "clock.badge.exclamationmark")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)

                if (chunking.resolvedEnrichmentModel ?? "").isEmpty {
                    Text("Без выбранной модели обогащение не выполняется: фрагменты уйдут в эмбеддинг как есть.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Цена обогащения словами: вызовов столько же, сколько чанков.
    ///
    /// Число чанков берётся из манифеста источника — это то, что он написал
    /// в прошлый раз. Пока источник не синхронизирован, называть количество
    /// нечем, и вместо выдуманного числа говорится правило. Время — только по
    /// измеренной скорости этой модели; не измерена — не называется (правило 4
    /// приложения 5).
    private var enrichmentCostLine: String {
        let chunking = draft.wrappedValue.chunking
        let chatModel = chunking.resolvedEnrichmentModel ?? ""
        // Строки таблиц живут в своём манифесте и в `chunks` не входят:
        // у источника таблиц счёт вызовов был бы иначе нулевым.
        let sourceID = draft.wrappedValue.id
        let counted = (model.manifestInfo[sourceID]?.chunks ?? 0) + (model.tableRows[sourceID] ?? 0)
        guard counted > 0 else {
            return String(localized: "Один вызов чат-модели на каждый чанк. Сколько их будет, станет известно после первой синхронизации источника.")
        }
        // Секунды на вызов — по фактической скорости **чат-модели**, тем же
        // счётчиком, что и у стенда оценки. Замер F3 сюда не годится:
        // он мерит пропускную способность эмбеддинга — сотни текстов
        // в секунду, — а генерация идёт секундами на вызов, и разница тут
        // в три порядка. Не измерено — не называется (правило 4 приложения 5).
        let estimate = ContextEnricher.estimate(
            chunks: counted,
            secondsPerCall: model.lastPlanMetrics.judgeSecondsPerCall(model: chatModel),
            basis: .measuredWork
        )
        // Не `estimate.line`: та строка написана про строки таблиц и здесь
        // читалась бы про чужое. Берём из неё только время.
        if let duration = estimate.durationText {
            return String(localized: "Один вызов чат-модели на чанк: \(counted.plainDigits) вызовов, \(duration) работы модели.")
        }
        return String(localized: "Один вызов чат-модели на чанк: \(counted.plainDigits) вызовов. Сколько это займёт — неизвестно: скорость этой модели ещё не измерялась.")
    }

    /// Сколько модель читает за раз — и влезает ли в это нарезка.
    ///
    /// Спрашивается здесь, потому что здесь и задаётся размер: узнать, что
    /// чанк длиннее читаемого, посреди прогона — узнать слишком поздно.
    /// Число не спрашивается у модели, а **измеряется**: то, что она о себе
    /// сообщает, с её поведением не совпадает. Проба стоит семи-восьми
    /// вызовов, поэтому она по кнопке, а не сама собой, и однажды измеренное
    /// помнится между запусками.
    @ViewBuilder
    private var modelReadingLimit: some View {
        let chunking = draft.wrappedValue.chunking
        let largest = chunking.largestChunkCharacters
        let model = draft.wrappedValue.embeddingModel
            ?? settings.configuration.defaultEmbeddingModel

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Сколько модель читает").font(Theme.Font.caption)
                if let inputLimit {
                    Text("≈ \(inputLimit.plainDigits) знаков за раз")
                        .font(Theme.Font.caption)
                } else if limitProbeFailed {
                    Text("измерить не вышло — модель не ответила")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
                } else if limitMeasured {
                    Text("больше \(EmbeddingInputProbe.maximumProbeCharacters.plainDigits) знаков — предела не нашлось")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                } else {
                    Text("не измерялось").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
                if isMeasuringLimit {
                    ProgressView().controlSize(.small)
                } else if let model, !model.isEmpty {
                    Button(limitMeasured ? String(localized: "Измерить заново") : String(localized: "Измерить")) {
                        Task { await measureLimit(model: model) }
                    }
                    .buttonStyle(.chromaNormal)
                }
                Spacer()
            }

            if let largest, let inputLimit, largest > inputLimit {
                Label(
                    String(localized: "При этих настройках чанк дорастает до \(largest.plainDigits) знаков — больше, чем модель читает. Такой файл уйдёт в пропущенные, а не в базу: вектор описывал бы только начало чанка."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
            } else if largest == nil {
                Text("Размер чанка при этих настройках ничем не ограничен: у document-based это «не делить», у LLM-based — то, что вернёт чат-модель. Приложение проверит каждый чанк на прогоне и пропустит файл, если он не влезет.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Модель молча обрезает то, что не влезло, — вектор считается по началу чанка, и ни в ответе, ни в выдаче это не видно. Поэтому предел измеряется пробой, а не берётся из того, что модель о себе сообщает.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: draft.wrappedValue.embeddingModel ?? "") {
            // Сначала забыть прежнее: число принадлежит модели, и оставить
            // его на экране после смены модели значит показать чужое.
            inputLimit = nil
            limitMeasured = false
            limitProbeFailed = false
            // Уже измеренное показывается сразу; мерить само собой — нет.
            guard let model, !model.isEmpty else { return }
            // Свежесть проверяется тем же признаком, что и в ядре:
            // иначе форма одобряла бы настройки числом, которое синхронизация
            // считает устаревшим и меряет заново.
            let loaded = await (try? app.makeLMStudioClient())?
                .reportedLoadedContextLength(of: model) ?? nil
            if let known = await app.embeddingLimits.limit(for: model),
               known.loadedContext == loaded {
                inputLimit = known.characters
                limitMeasured = true
            }
        }
    }

    private func measureLimit(model: String) async {
        isMeasuringLimit = true
        defer { isMeasuringLimit = false }
        guard let lmStudio = try? app.makeLMStudioClient() else {
            chunkingNotice = String(localized: "LM Studio недоступна — измерить предел нечем.")
            return
        }
        // Прежнее не стирается до успеха: сорвавшаяся проба не должна
        // отнимать то, что уже было измерено. Удачная — перезапишет
        // сама, `remember` заменяет запись по имени модели.
        // Через очередь: проба — это семь-восемь вызовов модели, то есть
        // длительная операция, и отнимать модель у идущей синхронизации
        // она не должна. Приоритет человека у экрана: он ждёт ответа
        // здесь и сейчас.
        // `do/catch`, а не `try?`: тот схлопывает вложенный `Optional`,
        // и «очередь сорвалась» стало бы неотличимо от «предела не нашлось»
        // — а это противоположные ответы.
        let outcome: Int?
        do {
            outcome = try await app.queue.run(QueueTicket(
                title: String(localized: "Замер предела чтения модели «\(model)»"),
                priority: .interactive,
                group: .lmStudio,
                connectionID: app.connectionID
            )) { _ in
                // Мимо кэша векторов: тексты пробы больше не понадобятся
                // никогда, а вытеснят они настоящие чанки.
                await EmbeddingInputProbe.measure { text in
                    try await lmStudio.embedIgnoringCache(texts: [text], model: model).first ?? []
                }
            }
        } catch {
            limitProbeFailed = true
            chunkingNotice = String(localized: "Замер не удался: модель не ответила. Прежнее измеренное значение сохранено.")
            return
        }
        limitProbeFailed = false
        limitMeasured = true
        inputLimit = outcome
        if let measured = outcome {
            // Контекст загрузки пишется вместе с числом: без него
            // ядро сверяет `nil` с настоящим контекстом, признаёт запись
            // устаревшей и гоняет пробу заново — то есть ручной замер
            // не экономил ни одного вызова модели.
            await app.embeddingLimits.remember(
                MeasuredInputLimit(
                    model: model,
                    characters: measured,
                    loadedContext: await lmStudio.reportedLoadedContextLength(of: model)
                )
            )
            app.log.record(
                .info, "Модели",
                "Модель «\(model)» читает за раз не больше \(measured.plainDigits) знаков — измерено пробой"
            )
        }
    }

    /// Умолчания нарезки.
    ///
    /// Здесь, а не на отдельном экране настроек: параметры стратегии
    /// настраивают в этом самом окне, теми же полями, и «пусть теперь так
    /// будет у всех» — это продолжение того же движения, а не отдельная
    /// работа в другом месте. Умолчание у каждой стратегии своё: переключение
    /// стратегии не должно возвращать заводские 512 токенов человеку, который
    /// уже настроил её под свои документы.
    @ViewBuilder
    private var chunkingDefaults: some View {
        let strategy = draft.wrappedValue.chunking.strategy
        let isOwn = settings.configuration.hasOwnChunkingDefault(for: strategy)
        let isForNewSources = (settings.configuration.defaultChunkingStrategy ?? ChunkingConfiguration().strategy) == strategy

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Умолчания").font(Theme.Font.caption)
                Button(String(localized: "Сделать умолчанием")) {
                    chunkingNotice = model.makeChunkingDefault(app)
                }
                .help(String(localized: "Запомнить эти значения для стратегии «\(strategy.title)» и заводить новые источники с ней"))
                Button(String(localized: "Взять умолчание")) {
                    chunkingNotice = model.takeChunkingDefault(app)
                }
                .help(String(localized: "Подставить сюда умолчания стратегии «\(strategy.title)»"))
                if isOwn {
                    Button(String(localized: "Забыть умолчание")) {
                        chunkingNotice = model.forgetChunkingDefault(app)
                    }
                    .help(String(localized: "Вернуть заводские значения стратегии «\(strategy.title)». Настройки этого источника не изменятся"))
                }
                Spacer()
            }
            Text(
                isOwn
                    ? (isForNewSources
                       ? String(localized: "У стратегии «\(strategy.title)» ваши умолчания, и новые источники заводятся с ней.")
                       : String(localized: "У стратегии «\(strategy.title)» ваши умолчания. Новые источники заводятся с другой стратегией."))
                    : String(localized: "У стратегии «\(strategy.title)» пока заводские умолчания.")
            )
            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            .fixedSize(horizontal: false, vertical: true)

            if let chunkingNotice {
                Label(chunkingNotice, systemImage: "info.circle")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unitPicker: some View {
        Picker("Единицы", selection: draft.chunking.sizeUnit) {
            ForEach(SizeUnit.allCases) { unit in
                Text(unit.title).tag(unit)
            }
        }
        .frame(width: 250)
    }

    private var sizeAndOverlap: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Stepper("chunk_size: \(draft.wrappedValue.chunking.chunkSize)", value: draft.chunking.chunkSize, in: 64...8192, step: 64)
                    .frame(width: 220)
                unitPicker
            }
            HStack {
                Text("overlap: \(Int(draft.wrappedValue.chunking.overlapPercent))%")
                Slider(value: draft.chunking.overlapPercent, in: 0...50, step: 5).frame(width: 200)
                Text("≈ \(draft.wrappedValue.chunking.overlapInCharacters) симв.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
        }
    }

    private var separatorsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Разделители по порядку, через |", text: $model.draftSeparators)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
            Text("`\\n` — перенос строки. Разбиение идёт по первому разделителю, который даёт куски нужного размера.")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
        }
    }

    private var documentBasedParameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Формат", selection: draft.chunking.sourceFormat) {
                ForEach(DocumentSourceFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }

            let format = DocumentSourceFormat.resolved(
                draft.wrappedValue.chunking.sourceFormat,
                fileExtension: draft.wrappedValue.fileExtensions.first
            )
            if format == .markdown {
                Stepper("резать по заголовкам уровня H\(draft.wrappedValue.chunking.splitHeaderLevel)", value: draft.chunking.splitHeaderLevel, in: 1...6)
                    .frame(width: 300)
            }
            if format == .html {
                TextField("Теги через запятую", text: Binding(
                    get: { draft.wrappedValue.chunking.splitTags.joined(separator: ", ") },
                    set: { text in
                        draft.wrappedValue.chunking.splitTags = text
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>/")) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            if format == .code {
                Picker("Резать по", selection: draft.chunking.codeSplitBy) {
                    ForEach(CodeSplitTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                Text("Границы определяются по объявлениям в начале строки — это эвристика, а не разбор языка.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft.wrappedValue.chunking.sourceFormat == .auto {
                Text("Формат определяется по расширению каждого файла: .html — как HTML, файлы кода — как код, остальное — как Markdown.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Stepper("max_section_size: \(draft.wrappedValue.chunking.maxSectionSize)", value: draft.chunking.maxSectionSize, in: 128...16384, step: 128)
                    .frame(width: 280)
                unitPicker
            }
            Picker("Крупные секции", selection: draft.chunking.oversizedFallback) {
                ForEach(OversizedSectionFallback.allCases) { fallback in
                    Text(fallback.title).tag(fallback)
                }
            }
            if draft.wrappedValue.chunking.oversizedFallback != .keep {
                fallbackCutting(
                    String(localized: "Этим и режется секция, которая не влезла. Перекрытие берётся отсюда обоими откатами; разделители — только Recursive."),
                    showsSeparators: draft.wrappedValue.chunking.oversizedFallback == .recursive
                )
            }
        }
    }

    /// Разделители и перекрытие показываются там, где они **действуют**
    ///.
    ///
    /// Их читают четыре стратегии — document-based в откате для крупных
    /// секций, hierarchical при разбиении длинной секции, adaptive у каждого
    /// блока и LLM-based при откате, — а поле было только у Recursive.
    /// Человек выбирал «Крупные секции → Recursive» и не видел, чем оно
    /// режет; поменять разделители можно было, только переключившись
    /// на Recursive, задав их там и вернувшись обратно.
    @ViewBuilder
    private func fallbackCutting(_ note: String, showsSeparators: Bool = true) -> some View {
        Divider()
        Text(note)
            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            .fixedSize(horizontal: false, vertical: true)
        if showsSeparators { separatorsField }
        HStack {
            Text("overlap: \(Int(draft.wrappedValue.chunking.overlapPercent))%")
            Slider(value: draft.chunking.overlapPercent, in: 0...50, step: 5).frame(width: 200)
        }
    }

    private var hierarchicalParameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper("уровней: \(draft.wrappedValue.chunking.levels)", value: draft.chunking.levels, in: 1...2)
                .frame(width: 200)
            HStack {
                Stepper("родитель: \(draft.wrappedValue.chunking.parentChunkSize)", value: draft.chunking.parentChunkSize, in: 256...16384, step: 256)
                    .frame(width: 240)
                unitPicker
            }
            HStack {
                Text("перекрытие родителя: \(Int(draft.wrappedValue.chunking.parentOverlapPercent))%")
                Slider(value: draft.chunking.parentOverlapPercent, in: 0...50, step: 5).frame(width: 160)
            }
            Stepper("ребёнок: \(draft.wrappedValue.chunking.childChunkSize)", value: draft.chunking.childChunkSize, in: 64...8192, step: 64)
                .frame(width: 240)
            HStack {
                Text("перекрытие ребёнка: \(Int(draft.wrappedValue.chunking.childOverlapPercent))%")
                Slider(value: draft.chunking.childOverlapPercent, in: 0...50, step: 5).frame(width: 160)
            }
            fallbackCutting(String(localized: "Раздел длиннее родителя режется на части — по этим разделителям и с этим перекрытием."))
            Text("Родительские и дочерние чанки лежат в одной коллекции: различаются полем chunk_level, ребёнок ссылается на родителя через parent_chunk_id.")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var semanticParameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Порог", selection: draft.chunking.thresholdMode) {
                ForEach(SemanticThresholdMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if draft.wrappedValue.chunking.thresholdMode == .percentile {
                HStack {
                    Text("перцентиль: \(Int(draft.wrappedValue.chunking.thresholdValue))")
                    Slider(value: draft.chunking.thresholdValue, in: 50...99, step: 1).frame(width: 200)
                }
            } else {
                HStack {
                    Text("расстояние: \(String(format: "%.2f", draft.wrappedValue.chunking.thresholdValue))")
                    Slider(value: draft.chunking.thresholdValue, in: 0.01...1, step: 0.01).frame(width: 200)
                }
            }
            Stepper("окно предложений: \(draft.wrappedValue.chunking.sentenceBuffer)", value: draft.chunking.sentenceBuffer, in: 1...5)
                .frame(width: 240)
            minMaxSize
            Picker("Модель для предложений", selection: Binding(
                get: { draft.wrappedValue.chunking.sentenceEmbeddingModel ?? "" },
                set: { draft.wrappedValue.chunking.sentenceEmbeddingModel = $0.isEmpty ? nil : $0 }
            )) {
                Text("та же, что у источника").tag("")
                ForEach(embeddings.embeddingModels) { item in
                    Text(item.id).tag(item.id)
                }
            }
        }
    }

    private var adaptiveParameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Stepper("базовый размер: \(draft.wrappedValue.chunking.baseChunkSize)", value: draft.chunking.baseChunkSize, in: 64...8192, step: 64)
                    .frame(width: 280)
                unitPicker
            }
            minMaxSize
            HStack {
                Text("чувствительность: \(String(format: "%.1f", draft.wrappedValue.chunking.sensitivity))")
                Slider(value: draft.chunking.sensitivity, in: 0...1, step: 0.1).frame(width: 200)
            }
            HStack {
                Text("overlap: \(Int(draft.wrappedValue.chunking.overlapPercent))%")
                Slider(value: draft.chunking.overlapPercent, in: 0...50, step: 5).frame(width: 200)
            }
            separatorsField
            Text("Плотный текст (числа, пунктуация, короткие предложения) режется мельче, разреженный — крупнее. Только эвристики, без модели-классификатора. Границы внутри блока ищутся по этим разделителям.")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var llmParameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Чат-модель", selection: Binding(
                get: { draft.wrappedValue.chunking.chatModel ?? "" },
                set: { draft.wrappedValue.chunking.chatModel = $0.isEmpty ? nil : $0 }
            )) {
                Text("не выбрана").tag("")
                ForEach(chatModelOptions, id: \.self) { id in
                    Text(id).tag(id)
                }
            }
            Picker("Гранулярность", selection: draft.chunking.granularity) {
                ForEach(LLMGranularity.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            HStack {
                Text("temperature: \(String(format: "%.2f", draft.wrappedValue.chunking.temperature))")
                Slider(value: draft.chunking.temperature, in: 0...1, step: 0.05).frame(width: 180)
            }

            // reproducibility outweighs everything else here, so the seed
            // is fixed unless the user deliberately unfixes it.
            HStack {
                Toggle("фиксированный seed", isOn: Binding(
                    get: { draft.wrappedValue.chunking.generation.seed != nil },
                    set: { on in
                        draft.wrappedValue.chunking.generation.seed = on ? ChatGenerationSettings.defaultSeed : nil
                    }
                ))
                if let seed = draft.wrappedValue.chunking.generation.seed {
                    TextField("seed", value: Binding(
                        get: { seed },
                        set: { draft.wrappedValue.chunking.generation.seed = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    Button("Случайный") {
                        draft.wrappedValue.chunking.generation.seed = Int.random(in: 1...999_999)
                    }
                    .font(Theme.Font.caption)
                }
            }
            Text(draft.wrappedValue.chunking.generation.seed == nil
                 ? "Без фиксированного seed повторная индексация того же файла может дать другие границы чанков."
                 : "Тот же файл при повторном прогоне разобьётся так же — переиндексация не создаёт беспричинных различий.")
                .font(Theme.Font.micro).foregroundStyle(draft.wrappedValue.chunking.generation.seed == nil ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            structuredOutputRow

            HStack {
                Stepper("max_chunk_size: \(draft.wrappedValue.chunking.maxChunkSize)", value: draft.chunking.maxChunkSize, in: 128...8192, step: 128)
                    .frame(width: 280)
                unitPicker
            }
            extendedGenerationBlock
            Picker("Если ответ не по формату", selection: draft.chunking.onMalformedOutput) {
                ForEach(MalformedOutputPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            HStack {
                Stepper("повторов: \(draft.wrappedValue.chunking.llmMaxRetries)", value: draft.chunking.llmMaxRetries, in: 0...5)
                    .frame(width: 160)
                Stepper("таймаут: \(Int(draft.wrappedValue.chunking.llmTimeout)) с", value: draft.chunking.llmTimeout, in: 10...600, step: 10)
                    .frame(width: 190)
            }

            Text("Шаблон запроса — {{TEXT}} подставляется текстом фрагмента:")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            TextEditor(text: Binding(
                get: { draft.wrappedValue.chunking.effectivePrompt },
                set: { draft.wrappedValue.chunking.promptTemplate = $0 }
            ))
            .font(Theme.Font.mono)
            .frame(height: 120)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            Button("Вернуть шаблон по умолчанию для этого режима") {
                draft.wrappedValue.chunking.promptTemplate = ""
            }
            .font(Theme.Font.caption).buttonStyle(.borderless)
        }
    }

    /// The model saved in the source stays in the list even before the list is
    /// loaded, so the picker never contradicts the indicator below it.
    private var chatModelOptions: [String] {
        ModelPickerOptions.merging(
            configured: draft.wrappedValue.chunking.chatModel,
            into: embeddings.chatModels.map(\.id)
        )
    }

    /// the form has to say which mode it is in — a schema-constrained
    /// answer and a best-effort parse fail in completely different ways.
    private var structuredOutputRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Structured Output (ответ по JSON-схеме)", isOn: draft.chunking.useStructuredOutput)
            Group {
                switch structuredOutputSupport {
                case .unknown:
                    Text("Поддержка схемы у выбранной модели ещё не проверена.")
                        .foregroundStyle(Theme.Palette.captionText)
                case .waiting:
                    Text("Локальная модель сейчас занята другой задачей — проверим поддержку схемы, когда она освободится. Источник можно сохранить и не дожидаясь.")
                        .foregroundStyle(Theme.Palette.captionText)
                case .checking:
                    Text("Проверяем поддержку схемы…").foregroundStyle(Theme.Palette.captionText)
                case .supported:
                    Text(draft.wrappedValue.chunking.useStructuredOutput
                         ? "Структурированный вывод поддерживается: сломанный JSON невозможен, резервный разбор не понадобится."
                         : "Модель поддерживает схему, но переключатель выключен — используется резервный разбор.")
                        .foregroundStyle(draft.wrappedValue.chunking.useStructuredOutput ? .green : .orange)
                case .unsupported:
                    Text("Структурированный вывод недоступен для этой модели — используется резервный разбор и правило «если ответ не по формату».")
                        .foregroundStyle(Theme.Palette.attention)
                }
            }
            .font(Theme.Font.micro)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// collapsed, and «empty means the field is not sent» — the same rule
    /// the HNSW parameters follow. Only parameters confirmed against a
    /// live LM Studio appear; `presence_penalty` is accepted and then ignored,
    /// so it is absent entirely rather than shown greyed out.
    private var extendedGenerationBlock: some View {
        DisclosureGroup(isExpanded: $showExtendedGeneration) {
            VStack(alignment: .leading, spacing: 6) {
                optionalField("top_p", value: draft.chunking.generation.topP, placeholder: "0…1")
                optionalIntField("top_k", value: draft.chunking.generation.topK, placeholder: "целое")
                optionalField("min_p", value: draft.chunking.generation.minP, placeholder: "0…1")
                optionalField("repeat_penalty", value: draft.chunking.generation.repeatPenalty, placeholder: "напр. 1.1")
                optionalField("frequency_penalty", value: draft.chunking.generation.frequencyPenalty, placeholder: "−2…2")
                optionalIntField("max_tokens", value: draft.chunking.generation.maxTokens, placeholder: "считается сам")

                Text("Пустое поле — параметр не передаётся вовсе: подставлять собственное представление о значении по умолчанию нельзя, у сервера и модели оно может быть другим.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                // Единственное исключение из правила выше, и оно названо здесь,
                // а не спрятано: это не догадка о чужом умолчании, а требование
                // предел считает приложение, от длины окна и от таймаута.
                Text("Кроме max_tokens при LLM-нарезке: пустое поле означает «считает приложение» — от размера окна и от того, сколько модель успевает написать за таймаут. Без предела модель, ушедшая в повтор, пишет до конца контекста и обрывается таймаутом.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("При temperature = 0 эти параметры на результат почти не влияют.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Модель, отвечающая рассуждением, тратит на него тот же лимит: слишком маленький max_tokens обрывает ответ до полезной части, и он считается некорректным.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } label: {
            Text("Расширенные параметры").font(Theme.Font.caption)
                .togglesDisclosure($showExtendedGeneration)
        }
    }

    private func optionalField(_ title: String, value: Binding<Double?>, placeholder: String) -> some View {
        HStack {
            Text(title).font(Theme.Font.mono).frame(width: 130, alignment: .leading)
            TextField(placeholder, text: Binding(
                get: { value.wrappedValue.map { String(format: "%g", $0) } ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    value.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
        }
    }

    private func optionalIntField(_ title: String, value: Binding<Int?>, placeholder: String) -> some View {
        HStack {
            Text(title).font(Theme.Font.mono).frame(width: 130, alignment: .leading)
            TextField(placeholder, text: Binding(
                get: { value.wrappedValue.map(String.init) ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    value.wrappedValue = trimmed.isEmpty ? nil : Int(trimmed)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
        }
    }

    private var minMaxSize: some View {
        HStack {
            Stepper("min: \(draft.wrappedValue.chunking.minChunkSize)", value: draft.chunking.minChunkSize, in: 32...4096, step: 32)
                .frame(width: 190)
            Stepper("max: \(draft.wrappedValue.chunking.maxChunkSize)", value: draft.chunking.maxChunkSize, in: 128...16384, step: 128)
                .frame(width: 210)
        }
    }

    private var triggers: some View {
        SectionCard(
            title: String(localized: "Когда синхронизировать"),
            subtitle: String(localized: "Режимы комбинируются; вручную можно всегда."),
            help: String(localized: "Таймеры живут, пока приложение запущено: фоновых демонов и launchd-агентов приложение не устанавливает. Запуск по изменениям в папке ждёт, пока правки утихнут, — массовое копирование даёт один запуск, а не сотню.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
            Toggle(String(localized: "Вручную — кнопкой на карточке"), isOn: .constant(true))
                .font(Theme.Font.control)
                .disabled(true)
                .help(String(localized: "Ручной запуск доступен всегда"))

            Toggle(String(localized: "При запуске приложения"), isOn: draft.triggers.onLaunch)
                .font(Theme.Font.control)

            Toggle(String(localized: "По расписанию"), isOn: draft.triggers.scheduled)
                .font(Theme.Font.control)
            if draft.wrappedValue.triggers.scheduled {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Режим", selection: draft.triggers.schedule.kind) {
                        ForEach(SyncSchedule.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if draft.wrappedValue.triggers.schedule.kind == .interval {
                        Stepper(
                            "каждые \(draft.wrappedValue.triggers.schedule.intervalMinutes) мин",
                            value: draft.triggers.schedule.intervalMinutes,
                            in: 5...1440,
                            step: 5
                        )
                        .frame(width: 260)
                    } else {
                        HStack {
                            Stepper("час: \(draft.wrappedValue.triggers.schedule.hour)", value: draft.triggers.schedule.hour, in: 0...23)
                                .frame(width: 150)
                            Stepper("минута: \(draft.wrappedValue.triggers.schedule.minute)", value: draft.triggers.schedule.minute, in: 0...59, step: 5)
                                .frame(width: 170)
                        }
                    }
                }
                .padding(Theme.Padding.rowHorizontal)
                .background(Theme.Palette.subtleFill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.row)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
            }

            Toggle(String(localized: "При изменениях в папке (FSEvents)"), isOn: draft.triggers.onFileChanges)
                .font(Theme.Font.control)
            if draft.wrappedValue.triggers.onFileChanges {
                HStack(spacing: 10) {
                    Text("пауза после последнего изменения").font(Theme.Font.control)
                    Stepper("\(Int(draft.wrappedValue.triggers.debounceSeconds)) с", value: draft.triggers.debounceSeconds, in: 1...120, step: 1)
                        .frame(width: 140)
                    Spacer(minLength: 0)
                }
            }

            Text("Удаления не выполняются автоматически ни в одном режиме: исчезнувшие файлы попадают в «Требуют решения».")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var metadata: some View {
        SectionCard(
            title: String(localized: "Метаданные источника"),
            subtitle: String(localized: "Свои поля, которые добавятся к каждому чанку этого источника."),
            // The extraction fields are listed separately because they are not
            // all unconditional: page_number and heading_path exist only where
            // the document has pages or an outline, and promising them for every
            // chunk would be a promise the pipeline cannot always keep.
            help: String(localized: "Приложение и так пишет в каждый чанк: \(SourceSyncService.autoMetadataKeys.joined(separator: ", ")). От извлечения добавляются \(SourceSyncService.extractionMetadataKeys.joined(separator: ", ")), а где документ это позволяет — page_number, page_count, heading_path и extraction_warnings. Поля ниже добавляются к ним, а не вместо них.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                ForEach($model.draftMetadataRows) { $row in
                    HStack(spacing: 10) {
                        TextField(String(localized: "ключ"), text: $row.key).textFieldStyle(.roundedBorder)
                        TextField(String(localized: "значение"), text: $row.value).textFieldStyle(.roundedBorder)
                        Button {
                            model.draftMetadataRows.removeAll { $0.id == row.id }
                            if model.draftMetadataRows.isEmpty { model.draftMetadataRows = [.init()] }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(Theme.Palette.captionText)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Убрать поле"))
                    }
                }
                HStack {
                    Button(String(localized: "Добавить поле")) {
                        model.draftMetadataRows.append(.init())
                    }
                    .buttonStyle(.chromaSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var schemaHookup: some View {
        SectionCard(
            title: String(localized: "Схема целевой коллекции"),
            subtitle: String(localized: "Совпадают ли поля источника с тем, что коллекция от них ждёт."),
            help: String(localized: "Схема — договор коллекции о метаданных: какие ключи обязательны и какого они типа. Источник закрывает её своими полями — автоматическими, извлечёнными и добавленными вручную. Если обязательное поле не закрыто, приложение спрашивает, что делать с такими чанками, а не решает само.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
            if let coverage {
                if coverage.isSatisfied {
                    Text("Схема коллекции «\(coverage.collectionName)» закрыта полностью.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.running)
                } else {
                    if !coverage.uncoveredRequiredFields.isEmpty {
                        Text("Не закрыты обязательные поля: \(coverage.uncoveredRequiredFields.joined(separator: ", "))")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(coverage.typeProblems) { problem in
                        Text(problem.message).font(Theme.Font.micro).foregroundStyle(Theme.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("Если поля не закрыты", selection: draft.unresolvedSchemaPolicy) {
                        ForEach(UnresolvedSchemaPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                Text("Источник даёт поля: \(coverage.providedKeys.joined(separator: ", "))")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("У коллекции «\(CollectionNaming.sanitize(draft.wrappedValue.collectionName))» схемы нет — метаданные ничем не ограничены.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(String(localized: "Сгенерировать черновик схемы из полей источника")) {
                        guard var source = model.draft else { return }
                        // Поля берутся из того, что набрано **в этом листе**,
                        // а не из сохранённого источника: иначе кнопка молчит
                        // ровно тогда, когда её и нажимают — сразу после того,
                        // как поля вписали.
                        source.customMetadata = Dictionary(
                            model.draftMetadataRows
                                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
                                .filter { !$0.0.isEmpty },
                            uniquingKeysWith: { _, last in last }
                        )
                        model.draftSchemaFromSource(source, app: app)
                        schemaNotice = model.infoMessage
                        model.infoMessage = nil
                        Task { await refreshCoverage() }
                    }
                    .buttonStyle(.chromaSecondary)
                    .disabled(model.draftMetadataRows.allSatisfy { $0.key.trimmingCharacters(in: .whitespaces).isEmpty })
                    Spacer(minLength: 0)
                }
                if let schemaNotice {
                    MessageBanner(kind: .success, text: schemaNotice) { self.schemaNotice = nil }
                }
            }
            }
        }
    }

    private func refreshCoverage() async {
        guard var source = model.draft else { return }
        source.customMetadata = Dictionary(
            model.draftMetadataRows
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
                .filter { !$0.0.isEmpty },
            uniquingKeysWith: { _, last in last }
        )
        coverage = await model.coverage(for: source, app: app)
    }
}

/// Полосы синхронизации — отдельным наблюдателем очереди.
///
/// Экран источников самый тяжёлый в приложении: 280 строк текста и 84 мелких
/// подписи. Пока он читал очередь сам, каждое её сообщение о прогрессе —
/// четырежды в секунду — перестраивало его целиком. Здесь перестраиваются
/// только полосы.
private struct SyncProgressRows: View {
    @EnvironmentObject private var queueMirror: QueueMirror
    /// Подпись собирает экран: она зависит от того, чем вызвана синхронизация,
    /// а это знание живёт в его модели.
    let label: (QueuedTaskInfo) -> String

    var body: some View {
        ForEach(queueMirror.tasks(titledWith: "Синхронизация")) { task in
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: task.progress ?? 0) {
                    Text(label(task)).font(Theme.Font.caption)
                }
                if let detail = task.detail {
                    Text(detail).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}
