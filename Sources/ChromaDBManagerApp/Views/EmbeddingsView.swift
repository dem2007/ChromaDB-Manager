import SwiftUI
import ChromaCore

struct EmbeddingsView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: EmbeddingsViewModel
    @ObservedObject var sources: SourcesViewModel
    @ObservedObject var autoSync: AutoSyncCoordinator
    @ObservedObject var collectionsModel: CollectionsViewModel
    /// Разрез экрана «Модели»: сами модели, кэш векторов, замеры.
    var tab: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if model.isChecking { ProgressView().controlSize(.small) }

                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let message = model.connectionMessage {
                    MessageBanner(kind: .success, text: message) { model.connectionMessage = nil }
                }
                if let warning = model.overrideWarning {
                    MessageBanner(kind: .warning, text: warning) { model.overrideWarning = nil }
                }

                // Экран «Модели» отвечает на один вопрос: чем считаются
                // векторы. Источники уехали на свой экран — раньше на одном
                // жили и подключение к LM Studio, и девять папок с
                // расписанием.
                switch tab {
                case 1:
                    cacheCard
                case 2:
                    BenchmarkTableSection(embeddings: model)
                    StatisticsSection(collectionsModel: collectionsModel, sources: sources)
                    // Ручные замеры моделей переехали сюда со «Стенда»
                    // источников: там спрашивают, как режется папка, здесь —
                    // чем считаются векторы.
                    ModelProbeSection(embeddings: model)
                default:
                    // Первым — то, ради чего экран открывают чаще всего:
                    // какой моделью считается всё по умолчанию.
                    defaultModelCard
                    lmStudioCard
                    modelsCard
                }
            }
            .padding(.top, 8)
            .pageContentPadding()
        }
        // Экран о моделях открывают, чтобы посмотреть на список, — и он
        // спрашивает LM Studio, не дожидаясь минутного такта.
        .task { await model.refreshModelsQuietly(app) }
    }

    /// Модель по умолчанию — первое, что видно на экране.
    ///
    /// Она отвечает на вопрос «чем считается всё, если не указано иное», и
    /// стояла последней строкой под таблицей моделей — там, где её читали
    /// после того, как уже перебрали глазами дюжину строк. Выбор переехал
    /// сюда же: в таблице он был колонкой с радиокнопками.
    private var defaultModelCard: some View {
        SectionCard(
            title: String(localized: "Модель по умолчанию"),
            subtitle: String(localized: "Ею создаются коллекции и считаются векторы текстовых запросов, если модель не указана явно."),
            help: String(localized: "У коллекции своя модель, привязанная навсегда: эта настройка задаёт лишь то, что подставляется при создании новой. Уже посчитанные векторы она не трогает.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                if model.embeddingModels.isEmpty {
                    Text("Список моделей пуст — проверьте соединение с LM Studio ниже.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                } else {
                    Picker("", selection: Binding(
                        get: { settings.configuration.defaultEmbeddingModel ?? "" },
                        set: { identifier in
                            guard let chosen = model.embeddingModels.first(where: { $0.id == identifier })
                            else { return }
                            model.selectDefaultModel(chosen, app: app)
                        }
                    )) {
                        Text(String(localized: "не выбрана")).tag("")
                        ForEach(model.embeddingModels) { item in
                            Text(item.id).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420, alignment: .leading)

                    if let measured = settings.configuration.defaultEmbeddingModel
                        .flatMap({ model.benchmark(for: $0) }) {
                        Text("измерено: \(String(format: "%.1f", measured.textsPerSecond)) текстов/с · размерность \(measured.dimension.plainDigits)")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                }
            }
        }
    }

    private var lmStudioCard: some View {
        SectionCard(
            title: String(localized: "LM Studio"),
            subtitle: lmStudioLine,
            help: String(localized: "По умолчанию http://localhost:1234. Если соединение не устанавливается — запустите LM Studio и включите Local Server в разделе Developer. Список моделей приложение обновляет само: раз в минуту, пока окно активно, и сразу при возврате в приложение. «Проверить соединение» делает больше — выясняет тип моделей, о которых API молчит, пробным запросом.")
        ) {
            HStack(spacing: 10) {
                TextField(String(localized: "Адрес локального сервера"), text: Binding(
                    get: { settings.configuration.lmStudioBaseURL },
                    set: { settings.configuration.lmStudioBaseURL = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

                Button(String(localized: "Проверить соединение")) {
                    Task { await model.checkConnection(app) }
                }
                .buttonStyle(.chromaNormal)
                .disabled(model.isChecking)
                Spacer()
            }
        }
    }

    /// Одной строкой: откуда берутся модели и когда список видели живым.
    ///
    /// «Пусто» и «не спрашивали» — разные вещи, и до этой строки экран их не
    /// различал: список моделей молча пустовал, пока человек не нажмёт кнопку
    ///.
    private var lmStudioLine: String {
        guard let refreshed = model.modelsRefreshedAt else {
            return String(localized: "Приложение не скачивает и не устанавливает модели — оно использует то, что уже доступно в LM Studio.")
        }
        return String(localized: "Приложение использует то, что уже доступно в LM Studio. Список обновлён в \(refreshed.formatted(date: .omitted, time: .standard)) — и обновляется сам, пока окно открыто.")
    }

    /// the cache is invisible in use, so the only way to know it works is a
    /// card that says how much it holds and how often it answered.
    private var cacheCard: some View {
        SectionCard(
            title: String(localized: "Кэш эмбеддингов"),
            subtitle: String(localized: "Вектор уже посчитанного текста берётся отсюда, а не у модели. На результаты не влияет — только на время.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "Использовать кэш"), isOn: Binding(
                    get: { settings.configuration.embeddingCacheEnabled },
                    set: { settings.configuration.embeddingCacheEnabled = $0 }
                ))
                .font(Theme.Font.control)

                if let statistics = model.cacheStatistics {
                    // Без иконок: это факты, а не состояния, и картинка рядом
                    // с числом ничего к нему не добавляет.
                    Text(statistics.hits + statistics.misses > 0
                         ? String(localized: "\(RussianCount.grouped(statistics.entries, "запись", "записи", "записей")) · \(statistics.sizeText) · за сеанс из кэша \(statistics.hits.formatted()) из \((statistics.hits + statistics.misses).formatted())")
                         : String(localized: "\(RussianCount.grouped(statistics.entries, "запись", "записи", "записей")) · \(statistics.sizeText) · за сеанс к кэшу не обращались"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.captionText)
                }

                HStack {
                    Text(String(localized: "Предел размера")).font(Theme.Font.control)
                    Stepper(
                        value: Binding(
                            get: { Double(settings.configuration.embeddingCacheLimitBytes) / 1_073_741_824 },
                            set: { value in Task { await model.applyCacheLimit(app, gigabytes: value) } }
                        ),
                        in: 0.5...50,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f ГБ", Double(settings.configuration.embeddingCacheLimitBytes) / 1_073_741_824))
                            .font(Theme.Font.mono)
                    }
                    .frame(width: 220)
                    Spacer()
                    // Не красная: данные от этого не теряются — теряется
                    // только уже посчитанное, и цена сказана строкой ниже.
                    Button(String(localized: "Очистить кэш")) {
                        Task { await model.clearCache(app) }
                    }
                    .buttonStyle(.chromaNormal)
                    .disabled(model.isClearingCache)
                }
                Text(String(localized: "При переполнении вытесняются записи, к которым дольше всего не обращались. После очистки векторы придётся считать заново — коллекции при этом не меняются."))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            }
        }
        .task { await model.refreshCacheStatistics(app) }
    }

    private var modelsCard: some View {
        SectionCard(
            title: String(localized: "Доступные модели"),
            subtitle: String(localized: "Что отдаёт LM Studio по адресу выше. Тип можно исправить вручную."),
            help: String(localized: "Тип берётся из ответа API; если API его не сообщает, он определяется пробным запросом к /v1/embeddings. «Реранкинг» ставится только вручную: LM Studio отдаёт переранжировщики обычными чат-моделями, и отличить их запросом нельзя. Помеченные так модели идут первыми в списке для переранжирования в «Умном поиске».")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if model.models.isEmpty {
                    Text(model.modelsRefreshedAt == nil
                         ? String(localized: "Список ещё не получен — приложение спрашивает LM Studio само, это займёт секунду.")
                         : String(localized: "LM Studio по адресу выше не отдала ни одной модели. Проверьте, что она запущена и Local Server включён."))
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // A table, not a card per model: with a dozen models the
                    // stack of cards was taller than the window.
                    TableCard {
                        TableHeaderRow(columns: [
                            (String(localized: "Модель"), nil),
                            (String(localized: "Тип"), 130),
                            (String(localized: "Контекст"), 150),
                            (String(localized: "Тип определён"), 150),
                        ])
                        ForEach(model.models) { item in
                            TableRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.id)
                                        .font(Theme.Font.monoCell)
                                        .lineLimit(1).truncationMode(.middle)
                                    // F3 lives inside the name cell rather than in
                                    // a column of its own: a column wide enough for
                                    // «Измерить скорость» took the width the model
                                    // id needs, and the id is what identifies the row.
                                    if item.kind == .embedding { benchmarkLine(item) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Picker("", selection: Binding(
                                    get: { item.kind },
                                    set: { model.overrideKind(item, to: $0, app: app) }
                                )) {
                                    ForEach(LMStudioModelKind.allCases, id: \.self) { kind in
                                        Text(kind.title).tag(kind)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 130, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.contextLine ?? "—")
                                        .font(Theme.Font.tableCell)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    // Контекст задаётся при загрузке модели, и
                                    // по сети его не поменять — только
                                    // перезагрузкой модели в LM Studio.
                                    if model.loadingModel == item.id {
                                        HStack(spacing: 5) {
                                            ProgressView().controlSize(.small)
                                            // Очередь держит группу локальной
                                            // модели последовательной:
                                            // перезагрузка ждёт конца того, что
                                            // уже идёт, — и молчать об этом
                                            // значит показывать зависшую
                                            // кнопку.
                                            Text(model.loadWaitsInQueue
                                                 ? String(localized: "ждёт очереди…")
                                                 : String(localized: "загружается…"))
                                                .font(Theme.Font.micro)
                                                .foregroundStyle(Theme.Palette.captionText)
                                        }
                                        .help(model.loadWaitsInQueue
                                              ? String(localized: "Локальная модель сейчас занята другой работой приложения. Перезагрузка начнётся, когда та закончится.")
                                              : String(localized: "LM Studio перезагружает модель"))
                                    } else if let range = model.reloadableContext(item) {
                                        Button(String(localized: "Загрузить с \(range.to.plainDigits)")) {
                                            model.requestLoad(item)
                                        }
                                        .buttonStyle(.link).font(Theme.Font.micro)
                                        .help(String(localized: "Перезагрузить модель в LM Studio с максимальным контекстом \(range.to.plainDigits) вместо нынешних \(range.from.plainDigits)."))
                                    }
                                }
                                .frame(width: 150, alignment: .leading)
                                .help(String(localized: "Потолок — что модель умеет; «загружена с» — с чем её подняли в LM Studio. Порождающие вызовы (чанкинг, переранжирование) упираются во второе. Размер задаётся при загрузке модели в LM Studio."))

                                // Радиокнопка «по умолчанию» уехала в карточку
                                // наверху экрана: выбор одной модели из списка —
                                // не свойство строки, а решение об экране.
                                Text(item.kindIsInferred
                                     ? String(localized: "приложением")
                                     : String(localized: "из API"))
                                    .font(Theme.Font.tableCell)
                                    .foregroundStyle(Theme.Palette.captionText)
                                    .lineLimit(1)
                                    .frame(width: 150, alignment: .leading)
                            }
                        }
                    }

                    // Сравнительная таблица замеров переехала на вкладку
                    // «Замеры»: там же, где средние времена прогонов.
                }
            }
        }
        .task { await model.refreshBenchmarks(app) }
        // Один `.alert` на вид: второй SwiftUI молча выбрасывает, и
        // подтверждение перезагрузки не показывалось никогда.
        .alert(item: $model.pendingAction) { action in
            switch action {
            case .benchmark(let name, let estimate):
                return Alert(
                    title: Text("Измерить скорость модели «\(name)»?"),
                    message: Text(benchmarkWarning(model: name, estimatedSeconds: estimate)),
                    primaryButton: .default(Text("Измерить")) { model.startBenchmark(app) },
                    secondaryButton: .cancel(Text("Отмена")) { model.cancelPendingAction() }
                )
            case .load(let name, let from, let to):
                // Перезагрузка модели — работа LM Studio, а не приложения: она
                // выгрузит модель у всех, кто ею пользуется, и займёт минуты и
                // гигабайты. Такое начинают по ответу человека (правило 4).
                return Alert(
                    title: Text("Перезагрузить «\(name)» с контекстом \(to.plainDigits)?"),
                    message: Text("Сейчас модель загружена с \(from.plainDigits). LM Studio выгрузит её и поднимет заново — это займёт время и больше памяти, а идущие сейчас запросы к ней прервутся.\n\nЕсли максимум окажется слишком тяжёлым, загрузите модель вручную в LM Studio с промежуточным значением."),
                    primaryButton: .default(Text("Перезагрузить")) { model.startLoad(app) },
                    secondaryButton: .cancel(Text("Отмена")) { model.cancelPendingAction() }
                )
            }
        }
    }

    /// F3, under the model's own name: what was measured, and the way to measure
    /// it. Only embedding models — the corpus goes through `/v1/embeddings`, and
    /// a chat model has nothing to answer it with.
    @ViewBuilder
    private func benchmarkLine(_ item: LMStudioModel) -> some View {
        HStack(spacing: 8) {
            if let measured = model.benchmark(for: item.id) {
                Text("\(String(format: "%.1f", measured.textsPerSecond)) текстов/с · батч \(measured.optimalBatchSize ?? 0) · размерность \(measured.dimension.plainDigits)")
                    .font(Theme.Font.micro).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.benchmarkingModel == item.id {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(height: 12)
                Text("измеряется…").font(Theme.Font.micro).foregroundStyle(.secondary)
            } else {
                Button(model.benchmark(for: item.id) == nil
                       ? String(localized: "Измерить скорость")
                       : String(localized: "Измерить заново")) {
                    Task { await model.requestBenchmark(item, app: app) }
                }
                .buttonStyle(.link)
                .font(Theme.Font.micro)
                .disabled(model.benchmarkingModel != nil)
            }
        }
    }

    /// Rule 4 of Приложение 5: warn before a long run, and never with a number
    /// nobody measured. Without a previous measurement the warning says what it
    /// knows — the number of calls — and admits it cannot say how long.
    private func benchmarkWarning(model: String, estimatedSeconds: Double?) -> String {
        let common = String(localized: "На время измерения модель занята: другие задачи к ней встанут в очередь. Прогон идёт мимо кэша — иначе измерялся бы кэш, а не модель.")
        guard let seconds = estimatedSeconds else {
            return String(localized: "Вызовов к модели: \(BenchmarkCorpus.totalCalls). Сколько это займёт — неизвестно: эта модель ещё ни разу не измерялась и в прогонах не участвовала. ") + common
        }
        return String(localized: "Примерно \(BenchmarkFormatting.duration(seconds)) — по прошлым измерениям этой модели. ") + common
    }

}

enum BenchmarkFormatting {
    /// Seconds where they read as seconds, minutes where they do not.
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return String(localized: "меньше секунды") }
        if seconds < 90 { return String(format: String(localized: "%.0f с"), seconds) }
        return String(format: String(localized: "%.0f мин"), (seconds / 60).rounded())
    }
}

/// Сравнительная таблица замеров: «Модели» → «Замеры».
///
/// Стояла под таблицей доступных моделей, на вкладке, которая отвечает на
/// вопрос «какие модели есть», — а отвечает она на другой: «какая из них
/// быстрее». Замеры теперь рядом со средними временами прогонов.
struct BenchmarkTableSection: View {
    @ObservedObject var embeddings: EmbeddingsViewModel

    var body: some View {
        SectionCard(
            title: String(localized: "Измеренные модели"),
            // «Замеров ещё не было» — неправда, когда файл замеров просто не
            // читается: они были, их не видно. Пустота и недоступность — разные
            // вещи, и подпись обязана их различать.
            subtitle: embeddings.benchmarksProblem != nil
                ? String(localized: "Файл замеров не читается — показывать нечего, пока это не исправлено.")
                : (embeddings.benchmarks.isEmpty
                    ? String(localized: "Замеров ещё не было. Запустить измерение можно у модели на вкладке «Модели».")
                    : String(localized: "Числа сравнимы между моделями: корпус фиксирован в коде и одинаков для всех прогонов.")),
            help: String(localized: "Первый вызов измеряется отдельно и в среднее не входит: во время него модель загружается в память, и это происходит один раз, а не на каждый текст. Если модель уже была загружена в LM Studio, первый вызов — обычный вызов; чтобы измерить именно загрузку, выгрузите модель перед запуском.")
        ) {
            // Следствие называется здесь же: сама по себе строка о файле не
            // говорит человеку, что он потеряет минуты занятой модели.
            if let problem = embeddings.benchmarksProblem {
                MessageBanner(
                    kind: .error,
                    text: String(localized: "\(problem) Новые замеры не сохранятся: после перезапуска их придётся делать заново.")
                )
                .padding(.bottom, Theme.Padding.rowSpacing)
            }
            if !embeddings.benchmarks.isEmpty {
                TableCard {
                    TableHeaderRow(columns: [
                        (String(localized: "Модель"), nil),
                        (String(localized: "Текстов/с"), 100),
                        (String(localized: "Батч"), 70),
                        (String(localized: "Размерность"), 110),
                        (String(localized: "Первый вызов"), 120),
                        (String(localized: "Измерено"), 150),
                    ])
                    ForEach(embeddings.benchmarks) { measured in
                        TableRow {
                            Text(measured.model)
                                .font(Theme.Font.monoCell)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.1f", measured.textsPerSecond))
                                .font(Theme.Font.tableCell)
                                .frame(width: 100, alignment: .leading)
                            Text((measured.optimalBatchSize ?? 0).plainDigits)
                                .font(Theme.Font.tableCell)
                                .frame(width: 70, alignment: .leading)
                            // A dimension is an identifier of the vector space,
                            // not a quantity: «2 560» reads as a count of things.
                            Text(measured.dimension.plainDigits)
                                .font(Theme.Font.tableCell)
                                .frame(width: 110, alignment: .leading)
                            Text(BenchmarkFormatting.duration(measured.firstCallSeconds))
                                .font(Theme.Font.tableCell)
                                .frame(width: 120, alignment: .leading)
                            Text(measured.measuredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.Font.tableCell)
                                .foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}
