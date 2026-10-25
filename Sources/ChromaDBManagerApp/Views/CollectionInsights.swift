import SwiftUI
import Charts
import ChromaCore

/// Что приложение может рассказать о коллекции: состав, проверки, темы.
///
/// Секциями формы: экран коллекции ставит их в свою `Form` на вкладках
/// «Обзор» и «Темы». Действие живёт в той секции, к которой относится:
/// «Проверить» — в проверках, «Построить обзор» — в составе, «Экспорт
/// отчёта» — в отчёте.
struct InspectorTabs: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: InspectorViewModel
    let collection: ChromaCollection
    /// Какую сторону показывать.
    let only: InspectorViewModel.Tab
    /// Показывать ли ответы работы — ошибку и сводку. Модель у сторон одна,
    /// и на вкладке из двух одно и то же сообщение выводилось дважды.
    var showsMessages: Bool = true
    /// Клик по значению фасета уводит в документы с готовым фильтром (K1 → A9).
    var applyFacetFilter: (String, MetadataValue) -> Void

    @State private var confirmingDeletion = false

    var body: some View {
        Group {
            if showsMessages { messages }
            switch only {
            case .checks: checksSections
            case .overview: overviewSections
            case .topics: topicsSections
            }
        }
        .task(id: collection.id) { model.prepare(for: collection) }
        .task(id: only) {
            // Список моделей нужен только темам — и спрашивается, когда их
            // открыли, а не при каждом показе.
            if only == .topics { model.loadChatModels(app: app) }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.errorMessage {
            Section {
                LabeledContent {
                    Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                        .buttonStyle(.borderless)
                } label: {
                    Notice(.warning, error)
                }
            }
        }
        if let message = model.statusMessage {
            Section {
                LabeledContent {
                    Button(String(localized: "Скрыть")) { model.statusMessage = nil }
                        .buttonStyle(.borderless)
                } label: {
                    Notice(.info, message)
                }
            }
        }
    }

    /// Ход работы — одна строка на все стороны: этап и доля.
    @ViewBuilder
    private var progressRow: some View {
        if let stage = model.stage {
            ProgressView(value: model.progress ?? 0) { Text(stage) }
                .progressViewStyle(.linear)
        }
    }

    /// Строка действий секции: главное действие и «Остановить» рядом с ним.
    /// «1 документ · 20 %» — словами и в локали интерфейса (v4 B), а не
    /// «1 · 20.0%».
    private func topicShare(_ count: Int, _ share: Double) -> String {
        "\(RussianCount.grouped(count, "документ", "документа", "документов")) · \(share.formatted(.percent.precision(.fractionLength(0))))"
    }

    /// Действие секции — строкой с подписью о состоянии (v4 A7), а не
    /// голой кнопкой справа. Кнопка обычная: выделенная — только в листах.
    private func actionRow(_ label: String, _ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        LabeledContent(label) {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button(String(localized: "Остановить")) { model.cancel() }
            }
            Button(title, action: action)
                .disabled(disabled || model.isRunning || !app.connection.isConnected)
        }
    }

    /// Темы называет модель, которой в LM Studio нет. Решается по списку,
    /// когда он пришёл: пустой список — ещё не спросили, а не «модели нет».
    private var topicModelMissing: Bool {
        model.namesTopics && !model.topicModel.isEmpty && !model.chatModels.isEmpty
            && !model.chatModels.contains(where: { $0.id == model.topicModel })
    }

    /// Число со стрелками — в одной строке с подписью.
    private func countRow(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int) -> some View {
        StepperRow(title, value: value, in: range, step: step)
    }

    // MARK: - Выборка

    /// Размер выборки — отдельной секцией и выше того, чем управляет:
    /// одно число задаёт объём чтения и составу, и проверкам.
    private var sampleSection: some View {
        Section {
            countRow(String(localized: "Размер выборки, документов"), value: $model.sampleSize, in: 100...100_000, step: 500)
        } header: {
            SectionHeader(
                String(localized: "Выборка"),
                help: String(localized: "У ChromaDB нет агрегирующих запросов: и состав, и проверки собираются чтением документов. Поэтому читается выборка, а не вся коллекция, — и сколько именно прочитано, написано в каждом отчёте.")
            )
        } footer: {
            Text("Общая для состава и проверок. Сто тысяч документов — это минуты работы базы.")
        }
    }

    // MARK: - Состав

    @ViewBuilder
    private var overviewSections: some View {
        sampleSection
        Section {
            if let overview = model.overview {
                if let lengths = overview.lengths { lengthRows(lengths) }
                if overview.facets.isEmpty {
                    Text("В метаданных выборки нет ни одного знакомого поля — распределять нечего.")
                        .foregroundStyle(.secondary)
                }
            }
            progressRow
            actionRow(
                model.overview == nil ? String(localized: "Обзор ещё не построен") : String(localized: "Обзор построен по выборке"),
                model.overview == nil ? String(localized: "Построить обзор") : String(localized: "Обновить обзор")
            ) { model.loadOverview(collection: collection, app: app) }
        } header: {
            SectionHeader(
                String(localized: "Состав коллекции"),
                help: String(localized: "Считается по выборке: у ChromaDB нет агрегирующих запросов, и «сколько документов у каждого источника» приходится собирать чтением. «Показать» уводит в список документов с этим условием.")
            )
        } footer: {
            Text(model.overview?.caption ?? String(localized: "Откуда пришли документы, каких они форматов и какой длины."))
        }
        if let overview = model.overview {
            ForEach(overview.facets) { facet in
                facetSection(facet)
            }
        }
    }

    /// Распределение — полосой системного индикатора и числом рядом.
    ///
    /// Перейти к документам с этим значением — двойным щелчком по строке или
    /// из контекстного меню (v3): ссылка «Показать» в узкой строке
    /// переносилась по буквам.
    private func distributionRow(_ title: String, count: Int, maximum: Int, action: (() -> Void)? = nil) -> some View {
        LabeledContent {
            ProgressView(value: Double(count), total: Double(max(maximum, 1)))
                .progressViewStyle(.linear)
                .accessibilityHidden(true)
            Text(count.formatted())
                .monospacedDigit()
                .fixedSize()
        } label: {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .help(action == nil ? title : String(localized: "\(title) — двойной щелчок покажет документы"))
        .onTapGesture(count: 2) { action?() }
        .contextMenu {
            if let action {
                Button(String(localized: "Показать документы"), action: action)
            }
        }
    }

    private func facetSection(_ facet: Facet) -> some View {
        let maximum = facet.values.map(\.count).max() ?? 1
        return Section {
            ForEach(facet.values) { value in
                distributionRow(value.text, count: value.count, maximum: maximum, action: value.filterValue.map { filterValue in
                    { applyFacetFilter(facet.field, filterValue) }
                })
            }
        } header: {
            Text(facet.title)
        } footer: {
            if facet.missing > 0 {
                Text("Без этого поля: \(facet.missing.plainDigits).")
            }
        }
    }

    /// Длины — столбчатым графиком (v3), а не строками формы.
    @ViewBuilder
    private func lengthRows(_ histogram: LengthHistogram) -> some View {
        LabeledContent(String(localized: "Длины документов, знаков")) {
            Text("медиана \(histogram.median.plainDigits), от \(histogram.shortest.plainDigits) до \(histogram.longest.plainDigits)")
                .monospacedDigit()
                .help(String(localized: "Горб у нуля — чанки, из которых ничего не найдётся; длинный хвост — чанки, которые модель прочитает не целиком."))
        }
        Chart(histogram.buckets) { bucket in
            BarMark(
                x: .value(String(localized: "Длина"), bucket.title),
                y: .value(String(localized: "Документов"), bucket.count)
            )
        }
        .formChartHeight()
        .accessibilityLabel(String(localized: "Распределение длин документов"))
    }

    // MARK: - Проверки

    @ViewBuilder
    private var checksSections: some View {
        Section {
            Toggle(String(localized: "Искать похожие документы"), isOn: $model.checksNearDuplicates)
                .help(String(localized: "Дорогая проверка: на каждый документ выборки — один запрос к базе. Векторы берутся из базы, заново ничего не считается."))
            if model.checksNearDuplicates {
                countRow(String(localized: "Документов для сравнения"), value: $model.nearDuplicateSampleSize, in: 50...20_000, step: 250)
            }
            // переименованная папка оставляет в базе чанки под прежним
            // путём, и убрать их можно только по решению человека.
            Toggle(String(localized: "Проверить, что файлы источников на месте"), isOn: $model.checksFilesOnDisk)
                .help(String(localized: "Обходит папки источников этой коллекции и показывает чанки файлов, которых на диске больше нет. Папку, которую не удалось прочитать (отключённый диск), проверка пропускает: «не знаем» честнее, чем «файлов нет»."))
            progressRow
            actionRow(
                model.report == nil ? String(localized: "Проверок ещё не было") : String(localized: "Итог последней проверки — ниже"),
                String(localized: "Проверить")
            ) {
                model.run(collection: collection, app: app)
            }
        } header: {
            SectionHeader(
                String(localized: "Проверки коллекции"),
                help: String(localized: "У ChromaDB нет агрегирующих запросов, поэтому инспектор читает выборку, а не всю коллекцию. Сколько именно прочитано — написано в отчёте. Каждая находка сопровождается предложением, а решение принимаете вы.")
            )
        } footer: {
            Text(model.report == nil && !model.isRunning
                 ? String(localized: "Прогонов ещё не было. Инспектор только читает и сообщает — ничего не исправляет сам.")
                 : String(localized: "Инспектор только читает и сообщает — ничего не исправляет сам."))
        }

        if let report = model.report {
            reportSection(report)
        }
        if let comparison = model.comparison { comparisonSection(comparison) }
        if model.history.count > 1 {
            historySection(model.history.prefix(10).map { ($0.startedAt, $0.line) })
        }
    }

    private func reportSection(_ report: InspectionReport) -> some View {
        let selected = model.selectedDocumentIDs()
        return Section {
            if report.acknowledged > 0 {
                LabeledContent {
                    Button(String(localized: "Показать снова")) { model.forgetAcknowledged(collection: collection) }
                        .buttonStyle(.link)
                } label: {
                    Text("Пропущено как уже просмотренное: \(report.acknowledged.plainDigits)")
                        .foregroundStyle(.secondary)
                }
            }
            selectionRow(report)
            ForEach(report.categoriesWithFindings) { category in
                categoryGroup(category, report: report)
            }
            HStack {
                // Уборка путей — по всей коллекции, а не по выделенному.
                if model.hasLegacyPaths {
                    Button(String(localized: "Привести пути к единой форме")) {
                        model.repairFilePaths(collection: collection, app: app)
                    }
                    .disabled(model.isRunning)
                    .help(String(localized: "Перепишет поля source_file, file_id и file_name у всей коллекции. Текст не меняется, векторы не пересчитываются."))
                }
                Menu(String(localized: "Экспорт отчёта")) {
                    Button(String(localized: "Markdown…")) { model.export(markdown: true, app: app) }
                    Button(String(localized: "JSON…")) { model.export(markdown: false, app: app) }
                }
                .fixedSize()
                Spacer()
                if !selected.isEmpty {
                    Button(String(localized: "Пометить как проверенное")) {
                        model.acknowledgeSelectedPairs(collection: collection)
                    }
                    Button(String(localized: "Удалить выбранные…"), role: .destructive) {
                        confirmingDeletion = true
                    }
                    .disabled(model.isRunning)
                    // Вопрос — на кнопке, а не на секции: на секции формы
                    // диалог не открывается.
                    .confirmationDialog(
                        String(localized: "Удалить документы: \(selected.count.plainDigits)?"),
                        isPresented: $confirmingDeletion,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Удалить"), role: .destructive) {
                            model.deleteSelected(collection: collection, app: app)
                        }
                        Button(String(localized: "Отменить"), role: .cancel) {}
                    } message: {
                        Text("Удаляются документы отмеченных находок — у дублей это документы пар, а не сами находки.")
                    }
                }
            }
        } header: {
            Text(report.problemCount > 0
                 ? String(localized: "Находки: \(report.problemCount.plainDigits)")
                 : String(localized: "Находок нет"))
        } footer: {
            Text(report.isSample
                 ? String(localized: "Проверено \(report.examined.plainDigits) документов из \(report.total.plainDigits) — это выборка, а не вся коллекция.")
                 : String(localized: "Проверено \(report.examined.plainDigits) документов — вся коллекция."))
        }
    }

    /// Что выбрано во всём отчёте и как выбрать всё разом. Удаляют
    /// документы, а отмечают находки, — это разные числа.
    @ViewBuilder
    private func selectionRow(_ report: InspectionReport) -> some View {
        let selectable = model.selectable()
        if !selectable.isEmpty {
            let chosen = model.selectedFindings.intersection(selectable.map(\.id)).count
            LabeledContent {
                Button(model.isEverythingSelected()
                       ? String(localized: "Снять выбор")
                       : String(localized: "Выбрать все замечания")) {
                    if model.toggleSelection() {
                        model.expanded.formUnion(report.categoriesWithFindings)
                    }
                }
                .buttonStyle(.link)
            } label: {
                Text(chosen > 0
                     ? String(localized: "Выбрано \(chosen.plainDigits) из \(selectable.count.plainDigits) · документов \(model.selectedDocumentIDs().count.plainDigits)")
                     : String(localized: "Ничего не выбрано"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryGroup(_ category: InspectionCategory, report: InspectionReport) -> some View {
        let findings = report.findings(in: category)
        let isExpanded = Binding(
            get: { model.expanded.contains(category) },
            set: { shown in
                if shown { model.expanded.insert(category) } else { model.expanded.remove(category) }
            }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            Text(category.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Что можно сделать: \(category.suggestion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(findings.prefix(200)) { finding in
                findingRow(finding, category: category)
            }
            if findings.count > 200 {
                Text("…и ещё \((findings.count - 200).plainDigits). Полный список — в экспортированном отчёте.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                if category.isInformational {
                    Text(category.title)
                } else {
                    StatusLabel(.warning, category.title)
                }
                Text(findings.count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                // Выбор всего разряда одним нажатием; выбранный
                // разряд тут же раскрывается — выбор, которого не видно,
                // не отличается от невыбранного.
                if !model.selectable(in: category).isEmpty {
                    Button(model.isEverythingSelected(in: category)
                           ? String(localized: "Снять выбор")
                           : String(localized: "Выбрать все")) {
                        if model.toggleSelection(in: category) {
                            model.expanded.insert(category)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            .togglesDisclosure(isExpanded)
        }
    }

    private func findingRow(_ finding: InspectionFinding, category: InspectionCategory) -> some View {
        LabeledContent {
            if category == .chunkGaps {
                Button(String(localized: "Забыть в манифесте")) {
                    model.forgetInManifest(file: finding.subject, collection: collection, app: app)
                }
                .help(String(localized: "Следующая синхронизация источника запишет этот файл заново. Сама она не запустится."))
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                if !finding.documentIDs.isEmpty {
                    Toggle(finding.subject, isOn: Binding(
                        get: { model.selectedFindings.contains(finding.id) },
                        set: { _ in model.toggleSelection(finding) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
                VStack(alignment: .leading) {
                    // У дублей находка названа началом текста — это проза;
                    // моноширинный — там, где в строке id или путь.
                    Text(finding.subject)
                        .font(category == .duplicates ? .body : .body.monospaced())
                        .lineLimit(category == .duplicates ? 2 : 1)
                        .truncationMode(category == .duplicates ? .tail : .middle)
                        .help(finding.subject)
                    if let detail = finding.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func comparisonSection(_ comparison: InspectionComparison) -> some View {
        Section {
            ForEach(comparison.changes) { change in
                if change.delta > 0 {
                    StatusLabel(.warning, change.line)
                } else {
                    Text(change.line).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(comparison.worsened
                 ? String(localized: "По сравнению с прошлым прогоном: стало хуже")
                 : (comparison.improved
                    ? String(localized: "По сравнению с прошлым прогоном: стало лучше")
                    : String(localized: "По сравнению с прошлым прогоном")))
        }
    }

    private func historySection(_ items: [(Date, String)]) -> some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                LabeledContent {
                    Text(item.1)
                } label: {
                    Text(item.0.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("История прогонов")
        } footer: {
            Text("Видно, стало лучше или хуже.")
        }
    }

    // MARK: - Темы

    @ViewBuilder
    private var topicsSections: some View {
        Section {
            // Своё имя: «Размер выборки» уже есть у проверки, с другим числом.
            countRow(String(localized: "Документов для поиска тем"), value: $model.topicSampleSize, in: 100...100_000, step: 1000)
            Toggle(String(localized: "Подбирать число тем автоматически"), isOn: $model.picksClusterCountAutomatically)
                .help(String(localized: "По размеру выборки: от четырёх тем до двадцати четырёх. У текстовых эмбеддингов нет «естественного» числа тем: если список вышел слишком крупным или дробным, задайте своё."))
            if !model.picksClusterCountAutomatically {
                countRow(String(localized: "Тем"), value: $model.clusterCount, in: 2...40, step: 1)
            }
            Toggle(String(localized: "Называть темы чат-моделью"), isOn: $model.namesTopics)
            if model.namesTopics {
                Picker(String(localized: "Модель"), selection: $model.topicModel) {
                    Text(String(localized: "не выбрана")).tag("")
                    // Выбранная модель, которой нет в списке (он ещё не
                    // пришёл из LM Studio или модель выгружена), — своим
                    // пунктом: иначе строка «Модель» пустела (v4 B).
                    if !model.topicModel.isEmpty, !model.chatModels.contains(where: { $0.id == model.topicModel }) {
                        // Только имя (v5): предупреждение — под секцией.
                        Text(model.topicModel).tag(model.topicModel)
                    }
                    ForEach(model.chatModels) { available in
                        Text(available.id).tag(available.id)
                    }
                }
            }
            progressRow
            actionRow(
                model.topicReport.map { String(localized: "Найдено тем: \($0.topics.count.formatted())") }
                    ?? String(localized: "Темы ещё не найдены"),
                model.topicReport == nil ? String(localized: "Найти темы") : String(localized: "Найти темы заново"),
                disabled: topicModelMissing
            ) { model.runTopics(collection: collection, app: app) }
        } header: {
            SectionHeader(
                String(localized: "Темы коллекции"),
                help: String(localized: "Документы группируются по близости векторов, каждая группа получает название от чат-модели. Результат — список тем с числами и примерами. Векторы берутся из базы, заново ничего не считается. Номера и названия тем в метаданные не записываются: это отчёт, а не изменение коллекции.")
            )
        } footer: {
            // Запрос уходит в модель — это отправка наружу, и она на экране.
            if topicModelMissing {
                Notice(.warning, String(localized: "Модели «\(model.topicModel)» нет в LM Studio — выберите другую в строке «Модель» или выключите «Называть темы чат-моделью», тогда темы просто пронумеруются."))
            } else {
                Text(model.namesTopics
                     ? String(localized: "Один запрос к модели на тему, не больше сорока за прогон; температура 0 — при тех же документах названия те же.")
                     : String(localized: "Без модели темы просто пронумеруются."))
            }
        }

        if let report = model.topicReport {
            topicReportSections(report)
        }
        if model.topicHistory.count > 1 {
            historySection(model.topicHistory.prefix(10).map { ($0.startedAt, $0.line) })
        }
    }

    @ViewBuilder
    private func topicReportSections(_ report: TopicReport) -> some View {
        Section {
            ForEach(report.notes, id: \.self) { note in
                Notice(.warning, note)
            }
            // Только таблица — так требует K2.3.
            ForEach(report.topics) { topic in
                LabeledContent(topic.title) {
                    Text(topicShare(topic.documentCount, topic.share))
                        .monospacedDigit()
                }
            }
            LabeledContent {
                Text(topicShare(report.unassigned.documentCount, report.unassigned.share))
                    .monospacedDigit()
            } label: {
                Text("Не отнесены ни к одной теме").foregroundStyle(.secondary)
            }
            // «Экспорт отчёта о темах» — в меню «⋯» тулбара (v6).
        } header: {
            // Отчёт сохраняется и показывается и через месяцы: без
            // даты его пометки «модель не назвала тему» читались как сбой
            // только что, хотя относятся к прогону, который был давно.
            Text("Темы — найдены \(report.startedAt.formatted(date: .abbreviated, time: .shortened))\(report.namingModel.map { String(localized: ", названия — \($0)") } ?? "")")
        } footer: {
            // Оценка качества — подписью под секцией, а не серой строкой в ней.
            // Только оценка качества: «Тем: N…» повторяло «Найдено тем: N»
            // строкой выше (v6).
            Text(report.quality)
        }

        ForEach(report.topics) { topic in
            Section {
                // Рассуждение модели в описании отсеивает сама тема — и при
                // разборе ответа, и при чтении сохранённого отчёта.
                if let summary = topic.summary {
                    Text(summary).foregroundStyle(.secondary)
                }
                ForEach(topic.examples) { example in
                    exampleRow(example)
                }
            } header: {
                HStack {
                    Text(topic.title)
                    if !topic.isNamed {
                        Text("без названия от модели").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(topicShare(topic.documentCount, topic.share))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            ForEach(report.unassigned.examples) { example in
                exampleRow(example)
            }
            if report.unassigned.examples.isEmpty {
                Text("Таких документов нет: выборка разошлась по темам целиком.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Не отнесены ни к одной теме — \(report.unassigned.documentCount.plainDigits)")
        } footer: {
            Text(report.unassigned.hasThreshold
                 ? String(localized: "Документы, до своего центра которых дальше остальных: часто здесь видно попавшее в коллекцию случайно. Порог: \((report.unassigned.distanceThreshold).decimal(3)) по косинусу.")
                 : String(localized: "Порога нет: расстояния до центров тем почти одинаковые, отделять нечего."))
        }
    }

    private func exampleRow(_ example: TopicExample) -> some View {
        VStack(alignment: .leading) {
            Text(example.id)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(example.excerpt)
                .lineLimit(3)
                .copyable(example.excerpt)
        }
    }
}
