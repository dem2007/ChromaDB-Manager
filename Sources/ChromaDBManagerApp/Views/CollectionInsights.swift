import SwiftUI
import ChromaCore

/// Что приложение может рассказать о коллекции: состав, проверки, темы.
///
/// Раньше это было модальное окно с собственной полосой вкладок и подвалом,
/// в котором лежали кнопки всех трёх сторон сразу. Когда окно встроили во
/// вкладки коллекции, подвал поехал с ним — и на экране оказались два ряда
/// «Проверить · Закрыть» подряд, ни один из которых не относился к карточке
/// над собой.
///
/// Теперь окна нет вовсе, а **действие живёт в той карточке, к которой
/// относится**: «Проверить» — в карточке проверок, «Построить обзор» — в
/// карточке состава, «Экспорт отчёта» — в карточке отчёта. Полоса вкладок
/// снаружи, у коллекции.
struct InspectorTabs: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: InspectorViewModel
    let collection: ChromaCollection
    /// Какую сторону показывать.
    let only: InspectorViewModel.Tab
    /// Синяя ли здесь кнопка. Когда панель на вкладке не одна, главным
    /// остаётся действие верхней карточки: двух синих кнопок на экране
    /// не бывает.
    var emphasisesAction: Bool = true
    /// Показывать ли ответы работы — ошибку и сводку. Модель у панелей одна,
    /// и на вкладке из двух панелей одно и то же сообщение выводилось дважды:
    /// над каждой карточкой по копии.
    var showsMessages: Bool = true
    /// Клик по значению фасета уводит в список документов с готовым фильтром
    /// (K1 → A9). Экран коллекций решает, как именно, — здесь только событие.
    var applyFacetFilter: (String, MetadataValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if showsMessages {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let message = model.statusMessage {
                    MessageBanner(kind: .info, text: message) { model.statusMessage = nil }
                }
            }
            switch only {
            case .checks: checksTab
            case .overview: overviewTab
            case .topics: topicsTab
            }
        }
        .task(id: collection.id) { model.prepare(for: collection) }
        .task(id: only) {
            // Список моделей нужен только теме — и спрашивается, когда её
            // открыли, а не при каждом показе инспектора.
            if only == .topics { model.loadChatModels(app: app) }
        }
    }

    /// Полоска хода работы — одна на все три вкладки: этап и доля.
    @ViewBuilder
    private var progressLine: some View {
        if let stage = model.stage {
            ProgressView(value: model.progress ?? 0) { Text(stage).font(Theme.Font.caption) }
                .progressViewStyle(.linear)
        }
    }

    /// Кнопка отмены — рядом с той кнопкой, которая работу начала.
    @ViewBuilder
    private var cancelButton: some View {
        if model.isRunning {
            Button(String(localized: "Остановить")) { model.cancel() }
                .buttonStyle(.chromaSecondary)
        }
    }

    /// Размер выборки — **своей карточкой, а не внутри проверок**.
    ///
    /// Одно число задаёт объём чтения и обзору состава, и проверкам, а стояло
    /// оно в карточке проверок: настройка выглядела принадлежащей одной из
    /// двух работ, которыми управляет. Управление стоит отдельно от того, чем
    /// управляет, и выше него — его меняют до нажатия, а не после.
    private var sampleCard: some View {
        SectionCard(
            title: String(localized: "Выборка"),
            subtitle: String(localized: "Сколько документов прочитать. Общая и для обзора состава, и для проверок."),
            help: String(localized: "У ChromaDB нет агрегирующих запросов: и состав, и проверки собираются чтением документов. Поэтому читается выборка, а не вся коллекция, — и сколько именно прочитано, написано в каждом отчёте.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                Stepper(
                    String(localized: "Размер выборки: \(model.sampleSize.plainDigits) документов"),
                    value: $model.sampleSize, in: 100...100_000, step: 500
                )
                .font(Theme.Font.body)
                Text("Чем больше выборка, тем дольше чтение и тем больше памяти оно занимает: сто тысяч документов — это минуты работы базы.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Проверки

    @ViewBuilder
    private var checksTab: some View {
        SectionCard(
            title: String(localized: "Проверки коллекции"),
            subtitle: String(localized: "Инспектор только читает и сообщает: ни одна проверка ничего не исправляет сама."),
            help: String(localized: "У ChromaDB нет агрегирующих запросов, поэтому инспектор читает выборку, а не всю коллекцию. Сколько именно прочитано — написано в отчёте. Каждая находка сопровождается предложением, а решение принимаете вы.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                Toggle(String(localized: "Искать похожие документы"), isOn: $model.checksNearDuplicates)
                    .font(Theme.Font.control)
                // Цена остаётся на экране: это запрос к базе на каждый
                // документ выборки, а не подробность устройства.
                Text("Дорогая проверка: на каждый документ выборки — один запрос к базе. Векторы берутся из базы, заново ничего не считается: иначе проверка стоила бы дороже переиндексации.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                if model.checksNearDuplicates {
                    Stepper(String(localized: "Документов для сравнения: \(model.nearDuplicateSampleSize.plainDigits)"), value: $model.nearDuplicateSampleSize, in: 50...20_000, step: 250)
                        .font(Theme.Font.body).padding(.leading, 16)
                }

                progressLine

                // Пустое состояние — внутри карточки, к которой относится:
                // фраза «прогонов ещё не было» на голом полотне не сообщала,
                // о чём она.
                if model.report == nil && !model.isRunning {
                    Text("Прогонов ещё не было: нажмите «Проверить», и инспектор прочитает выборку.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button(model.isRunning
                           ? String(localized: "Идёт проверка…")
                           : String(localized: "Проверить")) {
                        model.run(collection: collection, app: app)
                    }
                    .buttonStyle(emphasisesAction && model.report == nil ? .chromaPrimary : .chromaNormal)
                    .disabled(model.isRunning || !app.connection.isConnected)
                    cancelButton
                    Spacer()
                }
            }
        }

        if let report = model.report {
            reportCard(report)
        }

        if let comparison = model.comparison { comparisonCard(comparison) }
        if model.history.count > 1 { historyCard }
    }

    private func reportCard(_ report: InspectionReport) -> some View {
        SectionCard(
            title: report.problemCount > 0
                ? String(localized: "Находки: \(report.problemCount.plainDigits)")
                : String(localized: "Находок нет"),
            subtitle: report.isSample
                ? String(localized: "Проверено \(report.examined.plainDigits) документов из \(report.total.plainDigits) — это выборка, а не вся коллекция.")
                : String(localized: "Проверено \(report.examined.plainDigits) документов — вся коллекция.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                if report.acknowledged > 0 {
                    HStack(spacing: 6) {
                        Text("пропущено как уже просмотренное: \(report.acknowledged.plainDigits)")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        Button("показать снова") { model.forgetAcknowledged(collection: collection) }
                            .font(Theme.Font.micro).buttonStyle(.link)
                    }
                }
                ForEach(report.categoriesWithFindings) { category in
                    categoryRow(category, report: report)
                    if category != report.categoriesWithFindings.last { Divider() }
                }

                // Что делают с находками — здесь же, под ними: раньше это
                // лежало в подвале окна, за две карточки от списка.
                HStack(spacing: 8) {
                    let selected = model.selectedDocumentIDs()
                    if !selected.isEmpty {
                        Button(String(localized: "Пометить как проверенное")) {
                            model.acknowledgeSelectedPairs(collection: collection)
                        }
                        .buttonStyle(.chromaNormal)
                        Button(String(localized: "Удалить выбранные (\(selected.count.plainDigits))")) {
                            model.deleteSelected(collection: collection, app: app)
                        }
                        .buttonStyle(.chromaDanger)
                        .disabled(model.isRunning)
                    }
                    Spacer()
                    Menu {
                        Button("Markdown…") { model.export(markdown: true, app: app) }
                        Button("JSON…") { model.export(markdown: false, app: app) }
                    } label: {
                        Text("Экспорт отчёта")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 130)
                }
            }
        }
    }

    private func categoryRow(_ category: InspectionCategory, report: InspectionReport) -> some View {
        let findings = report.findings(in: category)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    model.toggle(category)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.expanded.contains(category) ? "chevron.down" : "chevron.right")
                            .font(Theme.Font.micro)
                        Text(category.title).font(Theme.Font.control).fontWeight(.medium)
                        Text("\(findings.count.plainDigits)")
                            .font(Theme.Font.micro)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(category.isInformational
                                        ? Theme.Palette.selectionFill
                                        : Theme.Palette.attention.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Text(category.explanation).font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Что можно сделать: \(category.suggestion)")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

            if model.expanded.contains(category) {
                ForEach(findings.prefix(200)) { finding in
                    findingRow(finding, category: category)
                }
                if findings.count > 200 {
                    Text("…и ещё \((findings.count - 200).plainDigits). Полный список — в экспортированном отчёте.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                }
            }
        }
    }

    private func findingRow(_ finding: InspectionFinding, category: InspectionCategory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !finding.documentIDs.isEmpty {
                Toggle("", isOn: Binding(
                    get: { model.selectedFindings.contains(finding.id) },
                    set: { _ in model.toggleSelection(finding) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 2) {
                // У дублей находка названа началом повторившегося текста, а
                // не идентификатором: это проза, и читается она обычным
                // шрифтом с обрезкой в конце. Моноширинный оставлен там, где
                // в строке действительно id или путь.
                Text(finding.subject)
                    .font(category == .duplicates ? Theme.Font.body : Theme.Font.mono)
                    .lineLimit(category == .duplicates ? 2 : 1)
                    .truncationMode(category == .duplicates ? .tail : .middle)
                if let detail = finding.detail {
                    Text(detail).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                }
            }
            Spacer(minLength: 4)
            if category == .chunkGaps {
                Button(String(localized: "Забыть в манифесте")) {
                    model.forgetInManifest(file: finding.subject, app: app)
                }
                .buttonStyle(.chromaSecondary)
                .help(String(localized: "Следующая синхронизация источника запишет этот файл заново. Сама она не запустится."))
            }
        }
        .padding(.leading, 16)
    }

    private func comparisonCard(_ comparison: InspectionComparison) -> some View {
        SectionCard(
            title: comparison.worsened
                ? String(localized: "По сравнению с прошлым прогоном: стало хуже")
                : (comparison.improved ? String(localized: "По сравнению с прошлым прогоном: стало лучше") : String(localized: "По сравнению с прошлым прогоном")),
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(comparison.changes) { change in
                    Text(change.line).font(Theme.Font.caption)
                        .foregroundStyle(change.delta > 0
                                         ? Theme.Palette.attention
                                         : Theme.Palette.captionText)
                }
            }
        }
    }

    private var historyCard: some View {
        SectionCard(
            title: String(localized: "История прогонов"),
            subtitle: String(localized: "Видно, стало лучше или хуже.")
        ) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.history.prefix(10)) { item in
                    HStack {
                        Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        Text(item.line).font(Theme.Font.caption)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Состав

    @ViewBuilder
    private var overviewTab: some View {
        sampleCard
        SectionCard(
            title: String(localized: "Состав коллекции"),
            subtitle: model.overview?.caption
                ?? String(localized: "Откуда пришли документы, каких они форматов и какой длины."),
            help: String(localized: "Считается по выборке: у ChromaDB нет агрегирующих запросов, и «сколько документов у каждого источника» приходится собирать чтением. Клик по «показать» уводит в список документов с этим условием.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                if let overview = model.overview {
                    if let lengths = overview.lengths { lengthCard(lengths) }
                    ForEach(overview.facets) { facet in
                        facetCard(facet)
                    }
                    if overview.facets.isEmpty {
                        Text("В метаданных выборки нет ни одного знакомого поля — распределять нечего.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                }

                progressLine

                HStack(spacing: 8) {
                    Button(model.isRunning
                           ? String(localized: "Считаю…")
                           : (model.overview == nil
                              ? String(localized: "Построить обзор")
                              : String(localized: "Обновить обзор"))) {
                        model.loadOverview(collection: collection, app: app)
                    }
                    .buttonStyle(model.overview == nil ? .chromaPrimary : .chromaNormal)
                    .disabled(model.isRunning || !app.connection.isConnected)
                    cancelButton
                    Spacer()
                }
            }
        }
    }

    private func facetCard(_ facet: Facet) -> some View {
        let maximum = max(facet.values.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(facet.title).font(Theme.Font.control).fontWeight(.medium)
                if facet.missing > 0 {
                    Text("без поля: \(facet.missing.plainDigits)")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                }
            }
            ForEach(facet.values) { value in
                HStack(spacing: 8) {
                    Text(value.text)
                        .font(Theme.Font.caption).lineLimit(1).truncationMode(.middle)
                        .frame(width: 220, alignment: .leading)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Palette.accent.opacity(0.35))
                            .frame(width: max(2, geometry.size.width * CGFloat(value.count) / CGFloat(maximum)))
                    }
                    .frame(height: 12)
                    Text(value.count.plainDigits).font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.captionText)
                        .frame(width: 60, alignment: .trailing)
                    if let filterValue = value.filterValue {
                        Button("показать") { applyFacetFilter(facet.field, filterValue) }
                            .font(Theme.Font.micro).buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func lengthCard(_ histogram: LengthHistogram) -> some View {
        let maximum = max(histogram.buckets.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Длины документов, знаков").font(Theme.Font.control).fontWeight(.medium)
            Text("Горб у нуля — чанки, из которых ничего не найдётся; длинный хвост — чанки, которые модель прочитает не целиком. Медиана \(histogram.median.plainDigits), от \(histogram.shortest.plainDigits) до \(histogram.longest.plainDigits).")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(histogram.buckets) { bucket in
                HStack(spacing: 8) {
                    Text(bucket.title).font(Theme.Font.caption)
                        .frame(width: 220, alignment: .leading)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Palette.accent.opacity(0.35))
                            .frame(width: max(2, geometry.size.width * CGFloat(bucket.count) / CGFloat(maximum)))
                    }
                    .frame(height: 12)
                    Text(bucket.count.plainDigits).font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.captionText)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Темы

    @ViewBuilder
    private var topicsTab: some View {
        SectionCard(
            title: String(localized: "Темы коллекции"),
            subtitle: String(localized: "Документы группируются по близости векторов, каждая группа получает название от чат-модели."),
            help: String(localized: "Результат — список тем с числами и примерами: ни проекций, ни диаграмм рассеяния здесь нет и не будет. Векторы берутся из базы, заново ничего не считается. Номера и названия тем в метаданные документов не записываются: это отчёт о коллекции, а не изменение в ней.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                Stepper(String(localized: "Размер выборки: \(model.topicSampleSize.plainDigits) документов"), value: $model.topicSampleSize, in: 100...100_000, step: 1000)
                    .font(Theme.Font.body)

                Toggle(String(localized: "Число тем по умолчанию"), isOn: $model.picksClusterCountAutomatically)
                    .font(Theme.Font.control)
                if !model.picksClusterCountAutomatically {
                    Stepper(String(localized: "Тем: \(model.clusterCount.plainDigits)"), value: $model.clusterCount, in: 2...40)
                        .font(Theme.Font.body).padding(.leading, 16)
                } else {
                    Text("По размеру выборки: от четырёх тем до двадцати четырёх. Это подробность, а не свойство коллекции — у текстовых эмбеддингов нет «естественного» числа тем. Если список получился слишком крупным или слишком дробным, задайте своё число.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Toggle(String(localized: "Называть темы чат-моделью"), isOn: $model.namesTopics)
                    .font(Theme.Font.control)
                if model.namesTopics {
                    Picker(String(localized: "Модель"), selection: $model.topicModel) {
                        Text(String(localized: "не выбрана")).tag("")
                        ForEach(model.chatModels) { available in
                            Text(available.id).tag(available.id)
                        }
                    }
                    .padding(.leading, 16)
                    // Запрос уходит в модель — это отправка наружу, и она
                    // остаётся на экране целиком.
                    Text("Один запрос к модели на тему — не больше сорока за прогон. Температура 0 и фиксированное зерно: при тех же документах названия получатся теми же. На ответ отводится пять минут: первый запрос уходит в модель, которая ещё загружается в память. Без модели темы просто пронумеруются.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 16)
                }

                progressLine

                if model.topicReport == nil && !model.isRunning {
                    Text("Прогонов ещё не было: нажмите «Найти темы», и приложение прочитает векторы выборки.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button(model.isRunning
                           ? String(localized: "Считаю…")
                           : (model.topicReport == nil
                              ? String(localized: "Найти темы")
                              : String(localized: "Найти темы заново"))) {
                        model.runTopics(collection: collection, app: app)
                    }
                    .buttonStyle(model.topicReport == nil ? .chromaPrimary : .chromaNormal)
                    .disabled(model.isRunning || !app.connection.isConnected)
                    cancelButton
                    Spacer()
                }
            }
        }

        if let report = model.topicReport {
            topicReportCard(report)
        }

        if model.topicHistory.count > 1 {
            SectionCard(title: String(localized: "История прогонов"), subtitle: nil) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.topicHistory.prefix(10)) { item in
                        HStack {
                            Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            Text(item.line).font(Theme.Font.caption)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func topicReportCard(_ report: TopicReport) -> some View {
        SectionCard(title: String(localized: "Темы"), subtitle: report.caption) {
            VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                Text(report.quality)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)

                if !report.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(report.notes, id: \.self) { note in
                            Text("• \(note)").font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Только таблица — так требует K2.3, и так звучало согласие.
                VStack(alignment: .leading, spacing: 0) {
                    topicRow(title: String(localized: "Тема"), count: String(localized: "Документов"), share: String(localized: "Доля"), isHeader: true)
                    Divider()
                    ForEach(report.topics) { topic in
                        topicRow(
                            title: topic.title,
                            count: topic.documentCount.plainDigits,
                            share: topic.sharePercent,
                            isHeader: false
                        )
                    }
                    Divider()
                    topicRow(
                        title: String(localized: "Не отнесены ни к одной теме"),
                        count: report.unassigned.documentCount.plainDigits,
                        share: report.unassigned.sharePercent,
                        isHeader: false,
                        isMuted: true
                    )
                }

                ForEach(report.topics) { topic in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(topic.title).font(Theme.Font.control).fontWeight(.medium)
                            if !topic.isNamed {
                                Text("без названия от модели")
                                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            }
                            Spacer()
                            Text("\(topic.documentCount.plainDigits) · \(topic.sharePercent)")
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        }
                        if let summary = topic.summary, !summary.isEmpty {
                            Text(summary).font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.captionText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(topic.examples) { example in
                            exampleRow(example)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Не отнесены ни к одной теме — \(report.unassigned.documentCount.plainDigits)")
                        .font(Theme.Font.control).fontWeight(.medium)
                    Text("Документы, до своего центра которых дальше остальных. Часто именно здесь видно то, что попало в коллекцию случайно. Порог: \(String(format: "%.3f", report.unassigned.distanceThreshold)) по косинусу.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(report.unassigned.examples) { example in
                        exampleRow(example)
                    }
                    if report.unassigned.examples.isEmpty {
                        Text("Таких документов нет: выборка разошлась по темам целиком.")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                }

                HStack {
                    Spacer()
                    Menu {
                        Button("Markdown…") { model.exportTopics(markdown: true, app: app) }
                        Button("JSON…") { model.exportTopics(markdown: false, app: app) }
                    } label: {
                        Text("Экспорт отчёта")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 130)
                }
            }
        }
    }

    private func topicRow(
        title: String, count: String, share: String, isHeader: Bool, isMuted: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.Font.caption).fontWeight(isHeader ? .semibold : .regular)
                .foregroundStyle(isMuted
                                 ? AnyShapeStyle(Theme.Palette.captionText)
                                 : AnyShapeStyle(Theme.Palette.primaryText))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count)
                .font(Theme.Font.caption).fontWeight(isHeader ? .semibold : .regular)
                .frame(width: 100, alignment: .trailing)
            Text(share)
                .font(Theme.Font.caption).fontWeight(isHeader ? .semibold : .regular)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private func exampleRow(_ example: TopicExample) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(example.id)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Palette.captionText)
                .lineLimit(1).truncationMode(.middle)
            Text(example.excerpt)
                .font(Theme.Font.micro)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 16)
    }
}
