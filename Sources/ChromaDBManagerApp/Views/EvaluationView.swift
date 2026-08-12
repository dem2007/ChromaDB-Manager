import SwiftUI
import ChromaCore

/// «Оценка» — прогон набора запросов по нескольким вариантам.
///
/// The screen shows the plan, then what the plan will cost, then the run. The
/// order is the point: D1.2 makes the cost mandatory before the start, because
/// a set of twenty queries against four variants is eighty searches and up to
/// eighty calls to a local model that nothing else can use meanwhile.
struct EvaluationView: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: EvaluationViewModel
    /// Разрез экрана: «Набор запросов», «Варианты», «Прогоны».
    var tab: Int = 0
    /// Перейти на соседнюю вкладку — например, к готовому прогону.
    var openTab: (Int) -> Void = { _ in }
    /// «Просмотр доступен и из результатов стенда оценки — при разметке
    /// результатов посмотреть исходник особенно нужно».
    @StateObject private var viewer = DocumentViewerViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                banners

                switch tab {
                case 1:
                    variantsCard
                    runCard
                    finishedRunNote
                case 2:
                    if model.lastRun != nil { reportCard }
                    if model.lastRun != nil { judgeCard }
                    if let run = model.lastRun { resultsCard(run) }
                    if !model.runs.isEmpty { historyCard }
                    if model.lastRun == nil && model.runs.isEmpty { noRunsCard }
                default:
                    setCard
                }

                howItWorks
            }
            .padding(.top, 4)
            .pageContentPadding()
        }
        .task { await model.load(app) }
        .sheet(isPresented: Binding(
            get: { model.draft != nil },
            set: { if !$0 { model.draft = nil } }
        )) {
            variantSheet
        }
        .sheet(isPresented: Binding(
            get: { viewer.request != nil },
            set: { if !$0 { viewer.close() } }
        )) {
            DocumentViewerSheet(model: viewer)
        }
        .sheet(isPresented: Binding(
            get: { model.setDraft != nil },
            set: { if !$0 { model.setDraft = nil } }
        )) {
            setSheet
        }
        .sheet(isPresented: Binding(
            get: { model.queryDraft != nil },
            set: { if !$0 { model.queryDraft = nil } }
        )) {
            querySheet
        }
        // Удаление набора уносит эталон — часы ручной работы. Спрашиваем, и
        // говорим, сколько именно отметок исчезнет (правило 1).
        .confirmationDialog(
            model.setPendingDeletion.map { String(localized: "Удалить набор «\($0.name)»?") } ?? "",
            isPresented: Binding(
                get: { model.setPendingDeletion != nil },
                set: { if !$0 { model.setPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить набор"), role: .destructive) { model.deleteSet(app) }
            Button(String(localized: "Отмена"), role: .cancel) { model.setPendingDeletion = nil }
        } message: {
            if let set = model.setPendingDeletion {
                Text("Вместе с набором исчезнет его эталон: \(set.line). Сохранённые прогоны останутся — они хранят свои запросы целиком.")
            }
        }
        .confirmationDialog(
            String(localized: "Удалить запрос из набора?"),
            isPresented: Binding(
                get: { model.queryPendingDeletion != nil },
                set: { if !$0 { model.queryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Удалить"), role: .destructive) { model.removeQuery(app) }
            Button(String(localized: "Отмена"), role: .cancel) { model.queryPendingDeletion = nil }
        } message: {
            if let query = model.queryPendingDeletion {
                Text(query.hasGroundTruth
                     ? "«\(query.text)» — вместе с запросом исчезнут и его отметки эталона."
                     : "«\(query.text)»")
            }
        }
        // 5 требует предупредить дважды: о стоимости и о том, что оценка
        // модели не истина. Оба предупреждения — в этом окне, до первого
        // вызова модели.
        .confirmationDialog(
            String(localized: "Запустить оценку чат-моделью?"),
            isPresented: Binding(
                get: { model.pendingJudgement != nil },
                set: { if !$0 { model.pendingJudgement = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Оценить")) { model.startJudgement(app) }
            Button(String(localized: "Отмена"), role: .cancel) { model.cancelPendingJudgement() }
        } message: {
            if let cost = model.pendingJudgement {
                Text("\(cost.line).\n\nПока идёт оценка, модель занята только этим. Её вывод — мнение модели, а не истина: он не попадает ни в эталон, ни в метрики, и принимать его нужно по одному, вручную.")
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let error = model.errorMessage {
            MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
        }
        if let status = model.statusMessage {
            MessageBanner(kind: .info, text: status) { model.statusMessage = nil }
        }
        if let exported = model.exportMessage {
            MessageBanner(kind: .info, text: exported) { model.exportMessage = nil }
        }
        // Эталон разметки — часы ручной работы. Если файл наборов не
        // прочитался, приложение ничего в него не пишет, и знать об этом надо
        // до, а не после разметки.
        if let problem = app.querySets.persistenceProblem {
            MessageBanner(kind: .error, text: problem)
        }
    }

    /// Прогон закончился на соседней вкладке — сказать об этом и увести туда.
    ///
    /// Без этой строки завершившийся прогон выглядел бы так, будто ничего не
    /// произошло: результаты живут на «Прогонах», а нажимали кнопку здесь.
    @ViewBuilder
    private var finishedRunNote: some View {
        if let run = model.lastRun, !model.isRunning {
            HStack(spacing: 12) {
                Circle().fill(Theme.Palette.running)
                    .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                Text("Готов прогон «\(run.name)» — результаты и метрики на вкладке «Прогоны».")
                    .font(Theme.Font.control)
                Spacer(minLength: 8)
                Button(String(localized: "Открыть прогон")) { openTab(2) }
                    .buttonStyle(.chromaNormal)
            }
            .padding(.horizontal, Theme.Padding.rowHorizontal)
            .padding(.vertical, Theme.Padding.rowVertical)
            .background(Theme.Palette.running.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.banner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.banner)
                    .strokeBorder(Theme.Palette.running.opacity(0.24), lineWidth: 1)
            )
        }
    }

    private var noRunsCard: some View {
        SectionCard(
            title: String(localized: "Прогонов пока нет"),
            subtitle: String(localized: "Прогон хранится целиком — с датой, версией приложения и полными параметрами вариантов.")
        ) {
            Text("Соберите набор запросов, добавьте хотя бы один вариант и нажмите «Прогнать» на вкладке «Варианты».")
                .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorks: some View {
        HowItWorks(screen: "evaluation") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Один набор запросов, несколько вариантов — и одна и та же выдача, сохранённая целиком. Вектор запроса считается один раз на модель и переиспользуется всеми вариантами с той же моделью.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Вариант — это коллекция плюс профиль поиска. Метрика расстояния и модель берутся из самой коллекции: сравнить другую модель или стратегию можно только по уже существующим коллекциям, потому что модель привязана к коллекции навсегда.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Оценка чат-моделью

    /// Необязательный режим, выключенный по умолчанию.
    ///
    /// Карточка стоит **после** отчёта и до результатов: оценка модели — это
    /// подсказка разметчику, а не источник чисел в таблице выше. Порядок на
    /// экране и есть это утверждение.
    private var judgeCard: some View {
        SectionCard(
            title: String(localized: "Оценка чат-моделью (необязательно)"),
            subtitle: String(localized: "Модель проходит по каждому результату каждого варианта и говорит, отвечает ли он на запрос. Это подсказка для разметки, а не разметка: в эталон и в метрики оценка модели не попадает — её можно только принять вручную.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Включить режим", isOn: Binding(
                    get: { app.settings.configuration.modelJudgeEnabled },
                    set: { enabled in
                        app.settings.configuration.modelJudgeEnabled = enabled
                        Task { await model.updateJudgeCost(app) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

                if app.settings.configuration.modelJudgeEnabled {
                    judgeSettings
                }

                if let set = model.judgements {
                    // Причина провала показывается **всегда**, а не только
                    // когда оценки есть. Прежнее условие прятало объяснение
                    // ровно в том случае, когда оно единственное, что можно
                    // сказать: «модель не ответила на 40 из 40» и ноль
                    // оценок — это одно событие, а не два.
                    if !set.judgements.isEmpty {
                        Text(set.line).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                    if !set.note.isEmpty {
                        Text(set.note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var judgeSettings: some View {
        Picker("Модель", selection: Binding(
            get: { app.settings.configuration.modelJudgeModel },
            set: { newValue in
                app.settings.configuration.modelJudgeModel = newValue
                Task { await model.updateJudgeCost(app) }
            }
        )) {
            Text("не выбрана").tag(String?.none)
            ForEach(model.chatModels) { item in
                Text(item.id).tag(Optional(item.id))
            }
        }
        .frame(maxWidth: 460, alignment: .leading)

        DisclosureGroup("Промпт оценки") {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: Binding(
                    get: { app.settings.configuration.modelJudgePrompt.text },
                    set: { app.settings.configuration.modelJudgePrompt.text = $0 }
                ))
                .font(Theme.Font.mono)
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Palette.border))

                Text("Подстановки \(JudgePrompt.queryPlaceholder) и \(JudgePrompt.documentPlaceholder) обязательны. Форма ответа задана схемой и не редактируется: разбор ответа написан ровно под неё.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                if let problem = app.settings.configuration.modelJudgePrompt.problem {
                    Text(problem).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                }
                if !app.settings.configuration.modelJudgePrompt.isDefault {
                    Button("Вернуть исходный промпт") {
                        app.settings.configuration.modelJudgePrompt = JudgePrompt()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 6)
        }
        .font(Theme.Font.body)

        if let cost = model.judgeCost {
            VStack(alignment: .leading, spacing: 4) {
                Text("Перед стартом").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                Text(cost.line).font(Theme.Font.body).copyable(cost.line)
                if cost.isLong {
                    Text("Пока идёт оценка, локальная модель занята: синхронизация, чанкинг и поиск встанут в очередь за ней.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                }
            }
        }

        if let progress = model.judgeProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text(progress.line).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
        }

        HStack {
            Button("Оценить моделью") { Task { await model.requestJudgement(app) } }
                .disabled(model.isJudging
                          || app.settings.configuration.modelJudgeModel == nil
                          || (model.judgeCost?.calls ?? 0) == 0)
            if model.isJudging {
                Button("Отменить") { model.cancelJudgement() }
                Text("Отмена сохраняет уже полученные оценки.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            } else if let cost = model.judgeCost, cost.calls == 0, cost.alreadyJudged > 0 {
                // Условие на посчитанной стоимости, а не на «nil ?? 0»:
                // «ещё не считали» — не то же самое, что «нечего делать»,
                // и первое, показанное как второе, — уже знакомая ошибка.
                Text("Всё оценено этой редакцией промпта. Правка промпта делает оценки заново.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
            Spacer()
        }
    }

    /// Оценка модели у одного результата — рядом с кнопками разметки, но
    /// заметно другой: курсив, серым, со словом «модель». Спутать её с
    /// собственной отметкой человека нельзя.
    @ViewBuilder
    private func judgementRow(queryID: UUID, variantID: UUID, hit: EvaluationHit) -> some View {
        if let judgement = model.judgement(queryID: queryID, variantID: variantID, hit: hit) {
            let accepted = model.grade(queryID: queryID, variantID: variantID, hit: hit) == judgement.grade
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("модель: \(judgement.grade.title)")
                        .font(Theme.Font.micro).italic()
                        .foregroundStyle(Theme.Palette.captionText)
                    if accepted {
                        Text("принято").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    } else {
                        Button("принять") {
                            model.acceptJudgement(judgement, hit: hit, app: app)
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                    }
                }
                if !judgement.reason.isEmpty {
                    Text(judgement.reason)
                        .font(Theme.Font.micro).italic()
                        .foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Набор и запрос: формы

    private var setSheet: some View {
        SheetShell(
            title: model.setDraft?.isNew == true
                ? String(localized: "Новый набор")
                : String(localized: "Переименовать набор"),
            subtitle: String(localized: "Набор принадлежит задаче, а не коллекции: один и тот же набор гоняется по разным вариантам."),
            width: 460,
            height: nil,
            scrolls: false
        ) {
            TextField(String(localized: "Название"), text: Binding(
                get: { model.setDraft?.name ?? "" },
                set: { model.setDraft?.name = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            TextField(String(localized: "Заметка"), text: Binding(
                get: { model.setDraft?.note ?? "" },
                set: { model.setDraft?.note = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
        } actions: {
            Button(String(localized: "Отмена")) { model.setDraft = nil }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Сохранить")) { model.saveSet(app) }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled((model.setDraft?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var querySheet: some View {
        SheetShell(
            title: model.queryDraft?.isNew == true
                ? String(localized: "Новый запрос")
                : String(localized: "Правка запроса"),
            subtitle: model.queryDraft?.isNew == false
                ? String(localized: "Эталон запроса правка не трогает: отметки релевантности — отдельная работа.")
                : String(localized: "Запрос набора: его текст и, если нужно, фильтр по метаданным."),
            width: 560,
            height: nil,
            scrolls: false
        ) {
            TextField(String(localized: "Текст запроса"), text: Binding(
                get: { model.queryDraft?.text ?? "" },
                set: { model.queryDraft?.text = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)

            TextField(String(localized: "Теги через запятую"), text: Binding(
                get: { model.queryDraft?.tags ?? "" },
                set: { model.queryDraft?.tags = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            TextField(String(localized: "Комментарий"), text: Binding(
                get: { model.queryDraft?.comment ?? "" },
                set: { model.queryDraft?.comment = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            queryFilterEditor
        } actions: {
            Button(String(localized: "Отмена")) { model.queryDraft = nil }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Сохранить")) { model.saveQuery(app) }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled((model.queryDraft?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Фильтр — тот же редактор, что на экране поиска, а не его копия.
    @ViewBuilder
    private var queryFilterEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Применять фильтр", isOn: Binding(
                get: { model.queryDraft?.filter != nil },
                set: { model.queryDraft?.filter = $0 ? (model.queryDraft?.filter ?? DocumentFilter()) : nil }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()

            if model.queryDraft?.filter != nil {
                ScrollView {
                    FilterNodeEditor(
                        node: Binding(
                            get: { model.queryDraft?.filter?.root ?? .group(.and, []) },
                            set: { model.queryDraft?.filter?.root = $0 }
                        ),
                        knownFields: model.filterFields(app),
                        depth: 0,
                        onRemove: nil
                    )
                }
                .frame(maxHeight: 220)
                Text("Фильтр применяется вместе с запросом, как на экране поиска. Поля предлагаются по схемам всех коллекций — набор не привязан к одной.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
        }
    }

    // MARK: - Отчёт

    private var reportCard: some View {
        SectionCard(
            title: String(localized: "Отчёт"),
            subtitle: String(localized: "Лучшее значение в столбце выделено — но только когда вариантов больше одного и значения различаются: «лучший из одинаковых» это не вывод.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ksControl
                if let table = model.table(app) { metricTable(table) }
                // Оговорка стоит сразу под таблицей, а не в примечаниях внизу:
                // она про то, как читать числа, которые человек видит сейчас.
                if let caveat = model.lengthCaveat {
                    Text(caveat).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                }
                divergentBlock
                comparisonBlock
                HStack(spacing: 8) {
                    Button("Экспорт в Markdown") { model.export(markdown: true, app: app) }
                    Button("Экспорт в JSON") { model.export(markdown: false, app: app) }
                }
                .controlSize(.small)
            }
        }
    }

    /// Настройка k. Стоит над таблицей, потому что меняет её столбцы.
    private var ksControl: some View {
        HStack(spacing: 8) {
            Text("Считать @k для:").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            ForEach([1, 3, 5, 10, 20], id: \.self) { k in
                let chosen = model.ks(app).contains(k)
                Button("@\(k)") { toggleK(k) }
                    .buttonStyle(.chromaNormal)
                    .controlSize(.small)
                    .tint(chosen ? Color.accentColor : nil)
            }
            Spacer()
        }
    }

    /// Снять последний оставшийся k нельзя: таблица без единой метрики
    /// выглядит поломкой, а не настройкой.
    private func toggleK(_ k: Int) {
        var current = Set(model.ks(app))
        if current.contains(k) {
            guard current.count > 1 else { return }
            current.remove(k)
        } else {
            current.insert(k)
        }
        app.settings.configuration.evaluationKs = EvaluationMetrics.sanitisedKs(Array(current))
        model.refreshMetrics(app)
    }

    private func metricTable(_ table: EvaluationReport.Table) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("Метрика").font(Theme.Font.caption).bold()
                        .frame(width: 150, alignment: .leading)
                    ForEach(Array(table.variantNames.enumerated()), id: \.offset) { _, name in
                        Text(name).font(Theme.Font.caption).bold()
                            .frame(width: 170, alignment: .leading).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
                Divider()
                ForEach(table.columns) { column in
                    HStack(spacing: 0) {
                        Text(column.title).font(Theme.Font.caption)
                            .frame(width: 150, alignment: .leading)
                        ForEach(Array(column.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell.text)
                                .font(Theme.Font.caption).monospacedDigit()
                                // Полужирный, а не цвет: цветом в этом экране
                                // уже размечены оценки релевантности, и второй
                                // смысл того же цвета читался бы как первый.
                                .fontWeight(cell.isBest ? .bold : .regular)
                                .foregroundStyle(cell.value == nil ? Color.secondary : Color.primary)
                                .frame(width: 170, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private var divergentBlock: some View {
        let rows = model.rows
        let divergent = EvaluationReport.mostDivergent(rows)
        let shown = model.showAllQueries ? rows : divergent
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.showAllQueries ? "Все запросы" : "Где варианты разошлись сильнее всего")
                    .font(Theme.Font.control).bold()
                Spacer()
                if !rows.isEmpty {
                    Button(model.showAllQueries ? "только расхождения" : "показать все") {
                        model.showAllQueries.toggle()
                    }
                    .controlSize(.small).buttonStyle(.borderless)
                }
            }
            if shown.isEmpty {
                Text(model.showAllQueries
                     ? "Запросов нет."
                     : "Расхождений нет: на всех запросах варианты повели себя одинаково либо судить не по чему — разметки не хватает.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            } else {
                ForEach(shown) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.text).font(Theme.Font.caption).bold().lineLimit(2)
                        HStack(spacing: 12) {
                            // Имена берутся из прогона, а не из плана на экране:
                            // у открытого сохранённого прогона план пуст, и
                            // исходы исчезали, оставляя строку без вывода.
                            // Найдено при открытии прогона после перезапуска.
                            ForEach(Array(zip((model.lastRun?.variants ?? []).map(\.name), row.outcomes)), id: \.0) { name, outcome in
                                Text("\(name): \(outcome.text)")
                                    .font(Theme.Font.micro)
                                    .foregroundStyle(Self.outcomeTint(outcome))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// «Не нашёл» — оранжевым, потому что это вывод о варианте.
    /// «Не размечено» — серым: это отсутствие вывода, и красить его как провал
    /// значило бы обвинять вариант в том, чего никто не проверял.
    private static func outcomeTint(_ outcome: EvaluationReport.QueryOutcome) -> Color {
        switch outcome {
        case .found: return .primary
        case .missed: return .orange
        case .unmarked: return .secondary
        case .failed: return .red
        }
    }

    private var comparisonBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Сравнить с прогоном").font(Theme.Font.control).bold()
                Picker("", selection: Binding(
                    get: { model.comparisonRunID },
                    set: { model.selectComparison($0, app: app) }
                )) {
                    Text("не сравнивать").tag(UUID?.none)
                    ForEach(model.runs.filter { $0.id != model.lastRun?.id }) { summary in
                        Text(summary.name).tag(UUID?.some(summary.id))
                    }
                }
                .labelsHidden().frame(width: 260)
            }
            if let comparison = model.comparison {
                if !comparison.onlyInBefore.isEmpty || !comparison.onlyInAfter.isEmpty {
                    Text("Сопоставлены только варианты с совпадающим именем."
                         + (comparison.onlyInBefore.isEmpty ? "" : " Только в «\(comparison.before)»: \(comparison.onlyInBefore.joined(separator: ", ")).")
                         + (comparison.onlyInAfter.isEmpty ? "" : " Только в «\(comparison.after)»: \(comparison.onlyInAfter.joined(separator: ", "))."))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                }
                ForEach(comparison.variants) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.variantName).font(Theme.Font.caption).bold()
                        ForEach(item.deltas) { delta in
                            if delta.before != nil || delta.after != nil {
                                Text("\(delta.title): \(delta.beforeText) → \(delta.afterText)"
                                     + (delta.changeText.map { " (\($0))" } ?? ""))
                                    .font(Theme.Font.micro).monospacedDigit()
                                    .foregroundStyle(Self.deltaTint(delta))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Без вердикта — обычным цветом. «Не изменилось» это не «не улучшилось».
    private static func deltaTint(_ delta: EvaluationReport.MetricDelta) -> Color {
        switch delta.improved {
        case true?: return .green
        case false?: return .orange
        default: return .secondary
        }
    }

    // MARK: - Набор

    private var setCard: some View {
        SectionCard(
            title: String(localized: "Набор запросов"),
            subtitle: String(localized: "Основной способ наполнения — кнопка «В набор» в истории поиска на экране коллекции: двадцать запросов руками никто не пишет. Здесь можно добавить недостающий, поправить опечатку и перенести набор на другую машину.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if model.sets.isEmpty {
                    Text("Ни одного набора пока нет. Выполните запрос на экране «Коллекции» и нажмите «В набор» под ним — или создайте набор здесь и впишите запросы сами.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                } else {
                    HStack(spacing: 8) {
                        // Пустой заголовок, а не скрытый: скрытая подпись
                        // всё равно держит колонку, и список отъезжал вправо.
                        Picker("", selection: Binding(
                            get: { model.selectedSetID },
                            set: { newValue in
                                model.selectedSetID = newValue
                                Task { await model.updateCost(app) }
                            }
                        )) {
                            ForEach(model.sets) { set in
                                Text(set.name).tag(Optional(set.id))
                            }
                        }
                        .labelsHidden()
                        // Выравнивание по левому краю: кнопка меню уже рамки,
                        // и без этого она вставала по центру, отъезжая вправо
                        // от всего остального в карточке.
                        .frame(minWidth: 160, idealWidth: 260, maxWidth: 260, alignment: .leading)
                        Spacer()
                    }

                    if let set = model.selectedSet {
                        Text(set.line).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        if !set.note.isEmpty {
                            Text(set.note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        if set.markedQueryCount < set.queries.count {
                            Text("Запросы без эталона всё равно прогоняются — их выдачу можно разметить прямо в результатах.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        queryList(set)
                    }
                }
                setActions
            }
        }
    }

    /// Запросы набора: текст, теги, эталон — и правка с удалением.
    private func queryList(_ set: QuerySet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 4)
            if set.queries.isEmpty {
                Text("В наборе нет запросов.").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
            ForEach(set.queries) { query in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(query.text).font(Theme.Font.body).lineLimit(2)
                        Text(Self.queryLine(query)).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer(minLength: 8)
                    Button(String(localized: "Править")) { model.editQuery(query) }
                        .buttonStyle(.chromaSecondary).disabled(model.isRunning)
                    Button(String(localized: "Удалить")) { model.queryPendingDeletion = query }
                        .buttonStyle(.chromaSecondary).disabled(model.isRunning)
                }
                .padding(.vertical, 3)
                Divider().opacity(0.4)
            }
        }
    }

    /// Что известно про запрос, кроме текста. Эталон назван числом, потому что
    /// именно он отличает запрос, по которому будут метрики, от остальных.
    private static func queryLine(_ query: EvaluationQuery) -> String {
        var parts: [String] = []
        let marks = query.fragments.count + query.documents.count
        parts.append(marks == 0
                     ? String(localized: "эталона нет")
                     : RussianCount.phrase(marks, "отметка эталона", "отметки эталона", "отметок эталона"))
        if query.filter != nil { parts.append(String(localized: "с фильтром")) }
        if !query.tags.isEmpty { parts.append(query.tags.joined(separator: ", ")) }
        if !query.comment.isEmpty { parts.append(query.comment) }
        return parts.joined(separator: " · ")
    }

    private var setActions: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Добавить запрос…")) { model.newQuery() }
                .buttonStyle(.chromaPrimary)
                .disabled(model.selectedSet == nil || model.isRunning)
            Spacer()
            Menu {
                Button("Новый набор…") { model.newSet() }
                Button("Переименовать…") { model.renameSet() }
                    .disabled(model.selectedSet == nil)
                Divider()
                Button("Экспорт набора…") { model.exportSet(app) }
                    .disabled(model.selectedSet == nil)
                Button("Импорт набора…") { model.importSet(app) }
                Divider()
                Button("Удалить набор", role: .destructive) { model.requestSetDeletion() }
                    .disabled(model.selectedSet == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
    }

    // MARK: - Варианты

    private var variantsCard: some View {
        SectionCard(
            title: String(localized: "Варианты"),
            subtitle: String(localized: "Метрика расстояния и модель берутся из самой коллекции — их нельзя выбрать здесь. Чтобы сравнить другую модель или стратегию, склонируйте коллекцию на экране «Эмбеддинги» → «Пересчёт векторов» → «Клонирование».")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if model.variants.isEmpty {
                    Text("Вариантов нет. Добавьте хотя бы один — сравнивать можно и два профиля поиска одной коллекции, это не требует клонирования.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                }
                ForEach(model.variants) { variant in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(variant.name).font(Theme.Font.body).bold()
                            Text(variant.line).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            if !variant.note.isEmpty {
                                Text(variant.note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            }
                        }
                        Spacer(minLength: 8)
                        Button(String(localized: "Убрать")) { model.removeVariant(variant, app: app) }
                            .buttonStyle(.chromaSecondary)
                            .disabled(model.isRunning)
                    }
                    Divider()
                }
                HStack {
                    Button(String(localized: "Добавить вариант")) { model.beginVariant(app) }
                        .buttonStyle(.chromaPrimary)
                        .disabled(model.isRunning || model.collections.isEmpty)
                    if model.collections.isEmpty {
                        Text("Нет подключения к базе или в ней нет коллекций.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer()
                }
            }
        }
    }

    private var variantSheet: some View {
        SheetShell(
            title: String(localized: "Новый вариант"),
            subtitle: String(localized: "Вариант — это коллекция плюс профиль поиска: их и сравнивает прогон."),
            help: String(localized: "Название варианта становится заголовком колонки в отчёте. Понятное имя («512 символов», «с переранжированием») читается через месяц, имя коллекции — нет."),
            width: 460,
            height: nil,
            scrolls: false
        ) {
            if let draft = model.draft {
                Picker(String(localized: "Коллекция"), selection: Binding(
                    get: { draft.collectionName },
                    set: { name in
                        model.draft?.collectionName = name
                        model.draft?.profileID = nil
                        model.draft?.name = name
                    }
                )) {
                    ForEach(model.collections) { collection in
                        Text(collection.name).tag(collection.name)
                    }
                }
                .font(Theme.Font.control)

                Picker(String(localized: "Профиль поиска"), selection: Binding(
                    get: { model.draft?.profileID },
                    set: { model.draft?.profileID = $0 }
                )) {
                    Text("Действующий для коллекции").tag(UUID?.none)
                    ForEach(model.profiles(for: draft.collectionName, app: app)) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .font(Theme.Font.control)

                Stepper(
                    "n_results: \(model.draft?.nResults ?? 10)",
                    value: Binding(
                        get: { model.draft?.nResults ?? 10 },
                        set: { model.draft?.nResults = $0 }
                    ),
                    in: 1...50
                )

                TextField(String(localized: "Название в отчёте"), text: Binding(
                    get: { model.draft?.name ?? "" },
                    set: { model.draft?.name = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        } actions: {
            Button(String(localized: "Отмена")) { model.draft = nil }
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Добавить")) { Task { await model.addVariant(app) } }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Прогон

    private var runCard: some View {
        SectionCard(
            title: String(localized: "Прогон"),
            subtitle: String(localized: "Вектор запроса считается один раз на модель и переиспользуется всеми вариантами с той же моделью.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let cost = model.cost {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Перед стартом").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        Text(cost.line).font(Theme.Font.body).copyable(cost.line)
                        if cost.isLong {
                            Text("Прогон длинный: пока он идёт, локальная модель занята — синхронизация и поиск встанут в очередь за ним.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                        }
                    }
                } else {
                    Text("Выберите набор и хотя бы один вариант — тогда здесь появится стоимость прогона.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                }

                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(
                            value: Double(progress.done),
                            total: Double(max(progress.total, 1))
                        )
                        Text(progress.line).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                }

                HStack {
                    Button(String(localized: "Прогнать")) { model.run(app) }
                        .buttonStyle(.chromaPrimary)
                        .disabled(!model.canRun)
                        .keyboardShortcut(.defaultAction)
                    if model.isRunning {
                        Button(String(localized: "Остановить")) { model.cancel() }
                            .buttonStyle(.chromaSecondary)
                        Text("Отмена сохраняет уже полученные результаты и помечает прогон неполным.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Результат

    private func resultsCard(_ run: EvaluationRun) -> some View {
        SectionCard(
            title: run.name,
            // Фактическое число вызовов эмбеддинга — часть подписи, а не
            // сообщение, исчезающее вместе с сеансом: сравнить его с оценкой
            // должно быть возможно и у прогона, открытого через месяц.
            subtitle: run.line + String(localized: " · вызовов эмбеддинга: \(run.embeddingCalls)")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if !run.note.isEmpty {
                    MessageBanner(kind: .warning, text: run.note)
                }
                metricsBlock
                Text("Отметка «релевантен / частично / нет» уходит в эталон набора как фрагмент найденного текста — она переживёт перенарезку и будет работать для других вариантов. Повторное нажатие той же оценки снимает её.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)

                // LazyVStack, а не VStack: прогон из пяти вариантов по десять
                // результатов — это двести карточек с текстом и тремя кнопками
                // каждая, и обычный стек строит их все до первого показа
                // экрана. Ленивый строит только видимое.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(run.queries) { query in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(query.text).font(Theme.Font.body).bold()
                            // Варианты — колонками рядом: различие видно
                            // только тогда, когда выдачи стоят друг напротив друга.
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(run.variants) { variant in
                                        resultColumn(run: run, query: query, variant: variant)
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    /// Выдача одного варианта на один запрос — колонка отчёта.
    private func resultColumn(
        run: EvaluationRun, query: EvaluationQuery, variant: EvaluationVariant
    ) -> some View {
        let result = run.result(query: query.id, variant: variant.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(variant.name).font(Theme.Font.caption).bold()
            if let failure = result?.failure {
                Text(failure).font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
            } else if let result {
                Text(Self.timing(result)).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                // Один раз на столбец, а не у каждого результата: причина
                // общая для всего прогона, и повторять её двадцать раз —
                // это шум, из-за которого её перестают читать.
                if !result.hits.isEmpty, result.hits.allSatisfy({ $0.metadata == nil }) {
                    Text("Прогон записан до того, как метаданные стали сохраняться: перехода к исходнику по нему нет. Прогоните набор заново.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.hits) { hit in
                    resultRow(queryID: query.id, variantID: variant.id, hit: hit)
                }
                if result.hits.isEmpty {
                    Text("ничего не найдено").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
            } else {
                Text("не выполнялся").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    /// Один результат с тремя кнопками — разметка прямо в отчёте.
    ///
    /// Здесь и нигде больше: главная проблема оценки в том, что эталона нет и
    /// размечать его скучно. Первый прогон и есть инструмент его создания.
    private func resultRow(queryID: UUID, variantID: UUID, hit: EvaluationHit) -> some View {
        let grade = model.grade(queryID: queryID, variantID: variantID, hit: hit)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(hit.position). \(Self.preview(hit))")
                .font(Theme.Font.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(RelevanceGrade.allCases) { candidate in
                    Button(candidate.title) {
                        model.mark(queryID: queryID, variantID: variantID, hit: hit, grade: candidate, app: app)
                    }
                    .buttonStyle(.chromaNormal)
                    .controlSize(.small)
                    .tint(grade == candidate ? Self.tint(candidate) : nil)
                    // Названия оценок не сокращаются никогда: «релеван…» и
                    // «нерелева…» отличаются четырьмя буквами в начале,
                    // и промахнуться на них — обычное дело.
                    .fixedSize()
                }
                if grade == nil {
                    // Ужимается первым: то же самое видно по тому, что ни
                    // одна из трёх кнопок не подсвечена.
                    Text("не размечено")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 4)
                // Размечать, не видя исходника, — гадание: чанк вырван из
                // документа, и понять, отвечает ли он на запрос, часто можно
                // только на месте.
                //
                // Кнопки нет вовсе, если исходник по этому результату не
                // найти. Неактивная кнопка с подсказкой не годится: подсказка
                // у выключенной кнопки не всплывает — проверено в окне, —
                // и человек видит серую надпись без единого объяснения.
                if !(hit.text ?? "").isEmpty && hit.metadata != nil {
                    // Значок, а не подпись: столбец варианта узкий и его
                    // ширина задана сравнением, а не этой кнопкой — со словами
                    // «в документе» названия оценок переносились на две строки.
                    Button {
                        viewer.open(
                            chunk: hit.text ?? "",
                            metadata: hit.metadata,
                            title: hit.id,
                            app: app
                        )
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help(String(localized: "Показать фрагмент в исходном документе"))
                }
            }
            judgementRow(queryID: queryID, variantID: variantID, hit: hit)
        }
        .padding(.vertical, 3)
    }

    private static func tint(_ grade: RelevanceGrade) -> Color {
        switch grade {
        case .relevant: return .green
        case .partial: return .orange
        case .irrelevant: return .red
        }
    }

    // MARK: - Метрики

    /// Метрики по вариантам — набором чисел, и намеренно без единой «общей
    /// оценки качества»: одно число прячет, какая из его частей сдвинулась, и
    /// создаёт уверенность, которой измерение не даёт.
    @ViewBuilder
    private var metricsBlock: some View {
        if !model.metrics.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Метрики").font(Theme.Font.control).bold()
                ForEach(model.metrics, id: \.variantID) { variantMetrics in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(variantMetrics.variantName).font(Theme.Font.body).bold()
                        Text(Self.line("hit rate", variantMetrics.hitRate))
                            .font(Theme.Font.caption).monospacedDigit()
                        Text(Self.line("recall", variantMetrics.recall))
                            .font(Theme.Font.caption).monospacedDigit()
                        Text(Self.line("nDCG", variantMetrics.ndcg))
                            .font(Theme.Font.caption).monospacedDigit()
                        Text("MRR \(variantMetrics.mrr.text)\(Self.basis(variantMetrics.mrr))")
                            .font(Theme.Font.caption).monospacedDigit()
                        if let latency = variantMetrics.searchLatency {
                            Text("поиск: \(latency.line)").font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        if let latency = variantMetrics.embeddingLatency {
                            Text("вектор запроса: \(latency.line) (посчитан \(RussianCount.phrase(latency.samples, "раз", "раза", "раз")))")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        ForEach(variantMetrics.truncatedKs, id: \.self) { k in
                            if let note = variantMetrics.note(for: k) {
                                Text(note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                            }
                        }
                        if let reason = Self.firstReason(variantMetrics) {
                            Text("«—» значит «неприменима»: \(reason)")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        Text(variantMetrics.coverage.line
                             + (variantMetrics.coverage.isComplete ? "" : String(localized: " — метрики предварительные")))
                            .font(Theme.Font.caption)
                            .foregroundStyle(variantMetrics.coverage.isComplete ? Theme.Palette.captionText : Theme.Palette.attention)
                    }
                }
            }
        }
    }

    private static func line(_ title: String, _ scores: [Int: MetricScore]) -> String {
        let parts = scores.keys.sorted().map { k in "@\(k) \(scores[k]?.text ?? "—")" }
        let queries = scores.values.compactMap { $0.value != nil ? $0.queries : nil }.max()
        let basis = queries.map { " · на \(RussianCount.phrase($0, "запросе", "запросах", "запросах"))" } ?? ""
        return "\(title) " + parts.joined(separator: " · ") + basis
    }

    private static func basis(_ score: MetricScore) -> String {
        guard score.value != nil else { return "" }
        return " · на \(RussianCount.phrase(score.queries, "запросе", "запросах", "запросах"))"
    }

    private static func firstReason(_ metrics: VariantMetrics) -> String? {
        let scores = Array(metrics.hitRate.values) + Array(metrics.recall.values)
            + Array(metrics.ndcg.values) + [metrics.mrr]
        return scores.first { $0.value == nil && $0.reason != nil }?.reason
    }

    private static func timing(_ result: EvaluationResult) -> String {
        var parts: [String] = []
        if let seconds = result.embeddingSeconds {
            parts.append(String(localized: "вектор \(Int(seconds * 1000)) мс"))
        } else if result.reusedVector {
            parts.append(String(localized: "вектор переиспользован"))
        }
        parts.append(String(localized: "поиск \(Int(result.searchSeconds * 1000)) мс"))
        parts.append(RussianCount.phrase(result.hits.count, "результат", "результата", "результатов"))
        return parts.joined(separator: " · ")
    }

    private static func preview(_ hit: EvaluationHit) -> String {
        let text = (hit.text ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return text.isEmpty ? hit.id : String(text.prefix(120))
    }

    // MARK: - Сохранённые прогоны

    private var historyCard: some View {
        SectionCard(
            title: String(localized: "Сохранённые прогоны"),
            subtitle: String(localized: "Прогон хранится целиком — с датой, версией приложения и полными параметрами вариантов.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.runs) { summary in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.name).font(Theme.Font.body)
                            Text(summary.line).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        Spacer(minLength: 8)
                        Button("Открыть") { model.openRun(summary, app: app) }
                        Button("Удалить") { model.removeRun(summary, app: app) }
                    }
                    Divider()
                }
            }
        }
    }
}
