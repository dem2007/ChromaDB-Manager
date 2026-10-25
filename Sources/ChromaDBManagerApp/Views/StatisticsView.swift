import SwiftUI
import ChromaCore

/// Вкладка «Замеры» экрана «Модели»: сколько на самом деле стоят модель
/// и стратегия — по прогонам этого приложения, а не по документации.
///
/// Тип Б: одна таблица на экран (v4) — разовые замеры скорости моделей,
/// средние времена эмбеддинга, средние времена нарезки, чем посчитана каждая
/// коллекция, строки из таблиц; что показать — выбором в тулбаре. Ручная
/// проверка модели на тексте — лист «Проверить модель…» из тулбара.
struct MeasurementsTab: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var embeddings: EmbeddingsViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel
    @ObservedObject var sources: SourcesViewModel

    @State private var metrics = MetricsSnapshot()
    /// how many rows came from which table.
    @State private var tables: [TableStatisticsRow] = []
    // Порядок, ширины и видимость колонок — помнит окно (v3).
    @SceneStorage("table.benchmarks.v3") private var benchmarkColumns: TableColumnCustomization<ModelBenchmark>
    @SceneStorage("table.modelMetrics.v3") private var modelMetricColumns: TableColumnCustomization<MetricsSnapshot.ModelMetric>
    @SceneStorage("table.strategyMetrics.v3") private var strategyColumns: TableColumnCustomization<MetricsSnapshot.StrategyMetric>
    @SceneStorage("table.tableRows.v3") private var tableRowColumns: TableColumnCustomization<TableStatisticsRow>
    @SceneStorage("table.origins.v3") private var originColumns: TableColumnCustomization<Row>
    /// Почему средние времена не сохраняются, если это так.
    @State private var metricsProblem: String?
    @State private var confirmsReset = false
    @State private var showsProbe = false
    /// Что показано: одна таблица на экран, выбор — в тулбаре (v4).
    @SceneStorage("measurements.part") private var part = Part.speed.rawValue

    var body: some View {
        // Одна таблица на экран (v4): три таблицы с фиксированной высотой
        // прокручивались каждая отдельно и срезали строки. Что показать —
        // выбором в тулбаре.
        VStack(spacing: 0) {
            switch currentPart {
            case .speed: benchmarksPane
            case .embedding: timingsPane(showsEmbedding: true)
            case .chunking: timingsPane(showsEmbedding: false)
            case .collections, .tableRows: collectionsPane
            }
            TableFooter(footerLine, help: currentPart.help)
        }
        .task { await refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Выбор — показанная часть, а не сохранённая: «Строки из
                // таблиц» без таблиц подменяются коллекциями, и пункта для
                // сохранённого значения в меню нет — пикер стоял бы пустым.
                Picker(String(localized: "Показать"), selection: Binding(
                    get: { currentPart.rawValue },
                    set: { part = $0 }
                )) {
                    ForEach(Part.allCases.filter { $0 != .tableRows || !tables.isEmpty }) { part in
                        Text(part.title).tag(part.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help(String(localized: "Какие замеры показать"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsProbe = true
                } label: {
                    Label(String(localized: "Проверить модель…"), systemImage: "waveform.path.ecg")
                }
                .help(String(localized: "Посчитать вектор, сравнить модели или близость двух текстов — прямо сейчас, на этой машине"))
                Button {
                    Task { await refresh() }
                } label: {
                    Label(String(localized: "Обновить"), systemImage: "arrow.clockwise")
                }
                Menu {
                    Button(String(localized: "Сбросить измерения…"), role: .destructive) { confirmsReset = true }
                        .disabled(metrics.isEmpty)
                } label: {
                    Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            String(localized: "Сбросить средние времена?"),
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Сбросить"), role: .destructive) {
                Task {
                    await app.metrics.reset()
                    await refresh()
                }
            }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text("Накопленные по прогонам времена сотрутся, и оценки длительности вернутся к «неизвестно» до следующих прогонов. Коллекции, кэш и разовые замеры моделей не затрагиваются.")
        }
        .sheet(isPresented: $showsProbe) {
            ModelProbeSheet(embeddings: embeddings) { showsProbe = false }
        }
    }

    private func refresh() async {
        metrics = await app.metrics.current()
        metricsProblem = await app.metrics.persistenceProblem()
        let store = app.tableManifests
        let sources = settings.configuration.dataSources
        tables = sources.flatMap { store.statistics(sourceID: $0.id, sourceName: $0.name) }
        await embeddings.refreshBenchmarks(app)
    }


    enum Part: String, CaseIterable, Identifiable {
        case speed, embedding, chunking, collections, tableRows

        var id: String { rawValue }

        var title: String {
            switch self {
            case .speed: return String(localized: "Скорость моделей")
            case .embedding: return String(localized: "Время эмбеддинга")
            case .chunking: return String(localized: "Время нарезки")
            case .collections: return String(localized: "Чем посчитаны коллекции")
            case .tableRows: return String(localized: "Строки из таблиц")
            }
        }

        /// Пояснение — подсказкой у строки статуса, а не заголовком над таблицей.
        var help: String {
            switch self {
            case .speed:
                return String(localized: "Разовые замеры на фиксированном корпусе — числа сравнимы между моделями. Первый вызов измеряется отдельно и в среднее не входит: во время него модель загружается в память. Если модель уже была загружена в LM Studio, первый вызов — обычный вызов; чтобы измерить именно загрузку, выгрузите модель перед запуском. Запускается у модели на вкладке «Модели».")
            case .embedding, .chunking:
                return String(localized: "Измерены на реальных прогонах этого приложения, а не взяты из документации моделей. Считается по завершённым синхронизациям и пересчётам: сколько секунд занял один текст у модели и один файл у стратегии. Сброс стирает накопленное, но не трогает ни коллекции, ни кэш.")
            case .collections:
                return String(localized: "Какая модель и какая стратегия стоят за каждой коллекцией — и когда её обновляли в последний раз.")
            case .tableRows:
                return String(localized: "Строка таблицы — это отдельный документ, а не кусок текста; считается по листам, а не по файлам.")
            }
        }
    }

    private var currentPart: Part {
        let chosen = Part(rawValue: part) ?? .speed
        // «Строки из таблиц» без таблиц — пустой экран; показываем коллекции.
        return chosen == .tableRows && tables.isEmpty ? .collections : chosen
    }

    private var showsTableRows: Bool { currentPart == .tableRows }

    private var footerLine: String {
        switch currentPart {
        case .speed: return String(localized: "Измерено моделей: \(embeddings.benchmarks.count.formatted())")
        case .embedding: return String(localized: "Моделей в прогонах: \(metrics.models.count.formatted())")
        case .chunking: return String(localized: "Стратегий в прогонах: \(metrics.strategies.count.formatted())")
        case .collections: return String(localized: "Коллекций: \(collectionsModel.collections.count.formatted())")
        case .tableRows: return String(localized: "Листов: \(tables.count.formatted())")
        }
    }

    // MARK: - Скорость моделей

    private var benchmarksPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // «Замеров ещё не было» — неправда, когда файл замеров просто не
            // читается: пустота и недоступность — разные вещи.
            if let problem = embeddings.benchmarksProblem {
                Notice(.warning, String(localized: "\(problem) Новые замеры не сохранятся: после перезапуска их придётся делать заново."))
                    .padding(.horizontal)
            }
            if embeddings.benchmarks.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Замеров ещё не было"), systemImage: "speedometer")
                } description: {
                    Text("Запустить измерение можно у модели на вкладке «Модели» — из контекстного меню строки.")
                }
            } else {
                Table(embeddings.benchmarks, columnCustomization: $benchmarkColumns) {
                    TableColumn(String(localized: "Модель")) { measured in
                        Text(measured.model)
                            .lineLimit(1).truncationMode(.middle)
                            .help(measured.model)
                    }
                    .customizationID("stat.модель")
                    TableColumn(String(localized: "Текстов/с")) { measured in
                        Text((measured.textsPerSecond).decimal(1)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90, max: 130)
                    .alignment(.numeric)
                    .customizationID("stat.текстов-с")
                    TableColumn(String(localized: "Батч")) { measured in
                        Text((measured.optimalBatchSize ?? 0).plainDigits).monospacedDigit()
                    }
                    .width(min: 40, ideal: 60, max: 80)
                    .alignment(.numeric)
                    .customizationID("stat.батч")
                    // A dimension is an identifier of the vector space, not a
                    // quantity: «2 560» reads as a count of things.
                    TableColumn(String(localized: "Размерность")) { measured in
                        Text(measured.dimension.plainDigits).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90, max: 130)
                    .alignment(.numeric)
                    .customizationID("stat.размерность")
                    TableColumn(String(localized: "Первый вызов")) { measured in
                        // «< 1 с», а не «меньше секунды»: не влезало (v4).
                        Text(measured.firstCallSeconds < 1
                             ? String(localized: "< 1 с")
                             : BenchmarkFormatting.duration(measured.firstCallSeconds))
                            .monospacedDigit()
                            .help(BenchmarkFormatting.duration(measured.firstCallSeconds))
                    }
                    .width(min: 70, ideal: 90, max: 130)
                    .alignment(.numeric)
                    .customizationID("stat.первый-вызов")
                    TableColumn(String(localized: "Измерено")) { measured in
                        Text(measured.measuredAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 110, ideal: 140, max: 200)
                    .customizationID("stat.измерено")
                }
            }
        }
    }

    // MARK: - Средние времена

    private func timingsPane(showsEmbedding: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let metricsProblem {
                Notice(.warning, String(localized: "\(metricsProblem) Средние времена не накапливаются: после перезапуска здесь снова будет пусто."))
                    .padding(.horizontal)
            }
            if metrics.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Пока нечего показывать"), systemImage: "clock")
                } description: {
                    Text(metricsProblem != nil
                         ? String(localized: "Накопленные времена не прочитаны — здесь пусто не потому, что прогонов не было.")
                         : String(localized: "Времена появятся после первой синхронизации или пересчёта."))
                }
            } else {
                if showsEmbedding {
                    Table(metrics.models.sorted { $0.model < $1.model }, columnCustomization: $modelMetricColumns) {
                        TableColumn(String(localized: "Эмбеддинг")) { metric in
                            Text(metric.model)
                                .lineLimit(1).truncationMode(.middle)
                                .help(metric.model)
                        }
                        .customizationID("stat.эмбеддинг")
                        TableColumn(String(localized: "с на текст")) { metric in
                            Text((metric.averageSeconds).decimal(3)).monospacedDigit()
                        }
                        .width(min: 70, ideal: 80, max: 110)
                        .alignment(.numeric)
                        .customizationID("stat.с-на-текст")
                        TableColumn(String(localized: "Текстов")) { metric in
                            Text(metric.texts.formatted()).monospacedDigit()
                        }
                        .width(min: 60, ideal: 80, max: 110)
                        .alignment(.numeric)
                        .customizationID("stat.текстов")
                    }
                } else {
                    Table(metrics.strategies.sorted { $0.strategy.rawValue < $1.strategy.rawValue }, columnCustomization: $strategyColumns) {
                        TableColumn(String(localized: "Нарезка")) { metric in
                            // LLM-based выделена: это единственная стратегия,
                            // чья цена должна быть заметна заранее.
                            if metric.strategy == .llmBased {
                                StatusLabel(.warning, metric.strategy.title)
                            } else {
                                Text(metric.strategy.title)
                            }
                        }
                        .customizationID("stat.нарезка")
                        TableColumn(String(localized: "На файл")) { metric in
                            Text(SecondsText.line(metric.averageSeconds, decimals: 2))
                        }
                        .width(min: 70, ideal: 90, max: 130)
                        .alignment(.numeric)
                        .customizationID("stat.на-файл")
                        TableColumn(String(localized: "Тыс. знаков/с")) { metric in
                            Text((metric.throughput).decimal(1)).monospacedDigit()
                        }
                        .width(min: 70, ideal: 90, max: 130)
                        .alignment(.numeric)
                        .customizationID("stat.тыс-знаков-с")
                        TableColumn(String(localized: "Прогонов")) { metric in
                            Text(metric.runs.formatted()).monospacedDigit()
                        }
                        .width(min: 60, ideal: 70, max: 100)
                        .alignment(.numeric)
                        .customizationID("stat.прогонов")
                    }
                }
            }
        }
    }

    // MARK: - Чем посчитаны коллекции

    private struct Row: Identifiable {
        let id: String
        let collection: String
        let source: String
        let model: String
        let strategy: String
        let dimension: String
        let documents: String
        let lastSync: String
    }

    private var rows: [Row] {
        collectionsModel.collections.map { collection in
            let sourceName: String
            if case .string(let name)? = collection.metadata?["_cdbm_source_name"] {
                sourceName = name
            } else {
                sourceName = "—"
            }

            let strategy: String
            if case .string(let raw)? = collection.metadata?["_cdbm_chunking_strategy"],
               let value = ChunkStrategy(rawValue: raw) {
                strategy = value.title
            } else {
                strategy = "—"
            }

            // The date comes from the source that fills the collection, and from
            // its manifest — a collection filled by hand has no sync date at all.
            let source = settings.configuration.dataSources.first { $0.name == sourceName }
            let lastSync: String
            if let date = source.flatMap({ sources.manifestInfo[$0.id]?.updatedAt ?? $0.lastSyncedAt }) {
                lastSync = date.formatted(date: .abbreviated, time: .shortened)
            } else {
                lastSync = "—"
            }

            return Row(
                id: collection.id,
                collection: collection.name,
                source: sourceName,
                model: collection.boundModel ?? "—",
                strategy: strategy,
                dimension: collection.effectiveDimension.map(\.plainDigits) ?? "—",
                documents: collection.documentCount.map { $0.formatted() } ?? "?",
                lastSync: lastSync
            )
        }
    }

    private var collectionsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTableRows && !tables.isEmpty {
                Table(tables, columnCustomization: $tableRowColumns) {
                    TableColumn(String(localized: "Файл")) { row in
                        Text(row.relativePath).lineLimit(1).truncationMode(.middle).help(row.relativePath)
                    }
                    .customizationID("stat.файл")
                    TableColumn(String(localized: "Лист")) { row in
                        Text(row.sheetName).lineLimit(1).truncationMode(.middle)
                    }
                    .customizationID("stat.лист")
                    TableColumn(String(localized: "Коллекция")) { row in
                        Text(row.collectionName).lineLimit(1).truncationMode(.middle)
                    }
                    .customizationID("stat.коллекция")
                    TableColumn(String(localized: "Строк")) { row in
                        Text(row.rows.formatted()).monospacedDigit()
                    }
                    .width(min: 60, ideal: 80, max: 110)
                    .alignment(.numeric)
                    .customizationID("stat.строк")
                }
            } else if collectionsModel.collections.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Коллекций нет"), systemImage: "square.stack.3d.up")
                } description: {
                    Text("Коллекций нет или список ещё не загружен — откройте раздел «Коллекции».")
                }
            } else {
                Table(rows, columnCustomization: $originColumns) {
                    TableColumn(String(localized: "Коллекция")) { row in
                        Text(row.collection).lineLimit(1).truncationMode(.middle).help(row.collection)
                    }
                    .customizationID("stat.коллекция")
                    TableColumn(String(localized: "Источник")) { row in
                        Text(row.source).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .customizationID("stat.источник")
                    TableColumn(String(localized: "Модель")) { row in
                        Text(row.model).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(row.model)
                    }
                    .width(min: 160, ideal: 300, max: 420)
                    .customizationID("stat.модель")
                    TableColumn(String(localized: "Стратегия")) { row in
                        Text(row.strategy).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110, max: 150)
                    .customizationID("stat.стратегия")
                    TableColumn(String(localized: "Размерность")) { row in
                        Text(row.dimension).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80, max: 110)
                    .alignment(.numeric)
                    .customizationID("stat.размерность")
                    TableColumn(String(localized: "Документов")) { row in
                        Text(row.documents).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90, max: 130)
                    .alignment(.numeric)
                    .customizationID("stat.документов")
                    TableColumn(String(localized: "Обновлена")) { row in
                        Text(row.lastSync).foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 130, max: 180)
                    .customizationID("stat.обновлена")
                }
            }
        }
    }
}
