import SwiftUI
import ChromaCore

/// Вкладка «Замеры» экрана «Модели»: сколько на самом деле стоят модель
/// и стратегия — по прогонам этого приложения, а не по документации.
///
/// Была одна карточка «Статистика» на пять разнородных блоков через
/// разделители: таблица коллекций, таблица листов, свод по моделям, кэш и
/// средние времена. Разложено по вопросам, а числа получили шкалу приложения:
/// системные `.caption` и `.caption2` давали свои кегли, не совпадающие ни с
/// чем вокруг.
struct StatisticsSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var collectionsModel: CollectionsViewModel
    @ObservedObject var sources: SourcesViewModel

    @State private var metrics = MetricsSnapshot()
    /// how many rows came from which table.
    @State private var tables: [TableStatisticsRow] = []
    /// Почему средние времена не сохраняются, если это так.
    @State private var metricsProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if let metricsProblem {
                MessageBanner(
                    kind: .error,
                    text: String(localized: "\(metricsProblem) Средние времена не накапливаются: после перезапуска здесь снова будет пусто.")
                )
            }
            timingsCard
            collectionsCard
        }
        .task { await refresh() }
    }

    private func refresh() async {
        metrics = await app.metrics.current()
        metricsProblem = await app.metrics.persistenceProblem()
        let store = app.tableManifests
        let sources = settings.configuration.dataSources
        tables = sources.flatMap { store.statistics(sourceID: $0.id, sourceName: $0.name) }
    }

    // MARK: - Средние времена

    /// Что показали прогоны — в отличие от разового замера модели выше.
    private var timingsCard: some View {
        SectionCard(
            title: String(localized: "Средние времена"),
            subtitle: String(localized: "Измерены на реальных прогонах этого приложения, а не взяты из документации моделей."),
            help: String(localized: "Считается по завершённым синхронизациям и пересчётам: сколько секунд занял один текст у модели и один файл у стратегии. Сброс стирает накопленное, но не трогает ни коллекции, ни кэш.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                if metrics.isEmpty, metricsProblem != nil {
                    Text("Накопленные времена не прочитаны — здесь пусто не потому, что прогонов не было.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if metrics.isEmpty {
                    Text("Пока нечего показывать: времена появятся после первой синхронизации или пересчёта.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if !metrics.models.isEmpty {
                        Text("Эмбеддинг").font(Theme.Font.control).fontWeight(.medium)
                        ForEach(metrics.models.sorted { $0.model < $1.model }) { metric in
                            Text("• \(metric.model): \(String(format: "%.3f", metric.averageSeconds)) с на текст (\(RussianCount.grouped(metric.texts, "текст", "текста", "текстов")))")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !metrics.strategies.isEmpty {
                        Text("Нарезка").font(Theme.Font.control).fontWeight(.medium)
                            .padding(.top, 4)
                        ForEach(metrics.strategies.sorted { $0.strategy.rawValue < $1.strategy.rawValue }) { metric in
                            // LLM-based выделена: это единственная стратегия,
                            // чья цена должна быть заметна заранее.
                            Text("• \(metric.strategy.title): \(Self.perFile(metric.averageSeconds)), \(String(format: "%.1f", metric.throughput)) тыс. знаков/с (\(RussianCount.grouped(metric.runs, "прогон", "прогона", "прогонов")))")
                                .font(Theme.Font.caption)
                                .foregroundStyle(metric.strategy == .llmBased
                                                 ? Theme.Palette.attention
                                                 : Theme.Palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button(String(localized: "Обновить")) { Task { await refresh() } }
                        .buttonStyle(.chromaNormal)
                    Spacer()
                    Button(String(localized: "Сбросить измерения")) {
                        Task {
                            await app.metrics.reset()
                            await refresh()
                        }
                    }
                    .buttonStyle(.chromaSecondary)
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

    private var collectionsCard: some View {
        SectionCard(
            title: String(localized: "Чем посчитаны коллекции"),
            subtitle: String(localized: "Какая модель и какая стратегия стоят за каждой коллекцией — и когда её обновляли в последний раз.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                if collectionsModel.collections.isEmpty {
                    Text("Коллекций нет или список ещё не загружен — откройте раздел «Коллекции».")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                } else {
                    // Горизонтальная прокрутка, а не перенос: имена моделей
                    // длинные, и сжатая колонка режет их до неразличимости.
                    ScrollView(.horizontal) {
                        TableCard {
                            TableHeaderRow(columns: [
                                (String(localized: "Коллекция"), 170),
                                (String(localized: "Источник"), 130),
                                (String(localized: "Модель"), 300),
                                (String(localized: "Стратегия"), 130),
                                (String(localized: "Размерность"), 100),
                                (String(localized: "Документов"), 100),
                                (String(localized: "Обновлена"), 150),
                            ])
                            ForEach(rows) { row in
                                TableRow {
                                    cell(row.collection, width: 170, emphasised: true)
                                    cell(row.source, width: 130)
                                    cell(row.model, width: 300, monospaced: true)
                                    cell(row.strategy, width: 130)
                                    cell(row.dimension, width: 100)
                                    cell(row.documents, width: 100)
                                    cell(row.lastSync, width: 150)
                                }
                            }
                        }
                    }

                    modelsSummary
                }

                if !tables.isEmpty {
                    AdvancedSection(place: "models.tables", title: String(localized: "Строки из таблиц")) {
                        Text("Строка таблицы — это отдельный документ, а не кусок текста; считается по листам, а не по файлам.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(tables) { row in
                            HStack(spacing: 8) {
                                Text(row.relativePath).font(Theme.Font.caption)
                                    .frame(width: 220, alignment: .leading)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(row.sheetName).font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.captionText)
                                    .frame(width: 160, alignment: .leading)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(row.collectionName).font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.captionText)
                                    .frame(width: 160, alignment: .leading)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(RussianCount.grouped(row.rows, "строка", "строки", "строк"))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.Palette.captionText)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Правило «округление, дающее ноль, заменяется словами» живёт одним
    /// местом на приложение — `SecondsText` (правило 6).
    /// Здесь остаётся только приписка «на файл».
    private static func perFile(_ seconds: Double) -> String {
        String(localized: "\(SecondsText.line(seconds, decimals: 2)) на файл")
    }

    private func cell(
        _ text: String, width: CGFloat, emphasised: Bool = false, monospaced: Bool = false
    ) -> some View {
        Text(text)
            .font(monospaced ? Theme.Font.monoCell : Theme.Font.tableCell)
            .fontWeight(emphasised ? .medium : .regular)
            .foregroundStyle(emphasised ? Theme.Palette.primaryText : Theme.Palette.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
    }

    /// Свод той же таблицы: сколько коллекций и документов держит каждая
    /// модель. Отдельной карточкой он был бы третьим списком об одном и том же.
    @ViewBuilder
    private var modelsSummary: some View {
        let grouped = Dictionary(grouping: rows.filter { $0.model != "—" }, by: \.model)
        if !grouped.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("По моделям").font(Theme.Font.control).fontWeight(.medium)
                ForEach(grouped.keys.sorted(), id: \.self) { model in
                    let group = grouped[model] ?? []
                    let documents = group
                        .compactMap { Int($0.documents.filter(\.isNumber)) }
                        .reduce(0, +)
                    Text("• \(model): \(RussianCount.grouped(group.count, "коллекция", "коллекции", "коллекций")), \(RussianCount.grouped(documents, "документ", "документа", "документов")), размерность \(group.first?.dimension ?? "—")")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
