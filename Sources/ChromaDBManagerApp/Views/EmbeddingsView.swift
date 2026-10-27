import SwiftUI
import ChromaCore

/// «Модели»: чем считаются векторы.
///
/// Вкладка «Модели» — модель по умолчанию и подключение к LM Studio формой,
/// под ними таблица доступных моделей (тип Б). «Кэш» — форма. «Замеры» —
/// таблицы (`MeasurementsTab`).
struct EmbeddingsView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: EmbeddingsViewModel
    @ObservedObject var sources: SourcesViewModel
    @ObservedObject var autoSync: AutoSyncCoordinator
    @ObservedObject var collectionsModel: CollectionsViewModel
    /// Разрез экрана «Модели»: сами модели, кэш векторов, замеры.
    var tab: Int = 0

    @State private var selectedModel: String?
    /// Порядок, ширины и видимость колонок — помнит окно (v3).
    @AppStorage(SettingsWindow.tabKey) private var settingsTab = SettingsWindow.Tab.general.rawValue
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("table.models.v3") private var columns: TableColumnCustomization<LMStudioModel>

    var body: some View {
        VStack(spacing: 0) {
            messages
            switch tab {
            case 1:
                connectionForm
            case 2:
                cacheForm
            case 3:
                MeasurementsTab(embeddings: model, collectionsModel: collectionsModel, sources: sources)
            default:
                modelsTab
            }
        }
        // Сообщения — у верхнего края. Без этого стопка «сообщение + пустой
        // список» не занимала высоту целиком, и SwiftUI ставил её по центру:
        // предупреждение висело посреди экрана.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Экран о моделях открывают, чтобы посмотреть на список, — и он
        // спрашивает LM Studio, не дожидаясь минутного такта.
        .task { await model.refreshModelsQuietly(app) }
    }

    /// Сообщения — строками над содержимым, как на остальных экранах.
    @ViewBuilder
    private var messages: some View {
        if model.errorMessage != nil || model.connectionMessage != nil || model.overrideWarning != nil {
            VStack(alignment: .leading) {
                if let error = model.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let message = model.connectionMessage {
                    HStack {
                        Notice(.info, message)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.connectionMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let warning = model.overrideWarning {
                    HStack {
                        Notice(.warning, warning)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.overrideWarning = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding()
            Divider()
        }
    }

    // MARK: - Модели

    /// Эмбеддинг по умолчанию и LM Studio — своей вкладкой (v3): у
    /// вкладки «Модели» один контейнер — таблица.
    private var connectionForm: some View {
        VStack(spacing: 0) {
            providerBar
            Form {
                defaultModelSection
                lmStudioSection
            }
            .formStyle(.grouped)
        }
        // Смену сервера — сброс списка и новый запрос — ведёт приложение
        // (`AppEnvironment.providerSwitchWatch`), а не этот экран.
    }

    /// Сервер моделей — сегментами в начале вкладки, как части прогонов
    /// на «Оценке». Выбранный сегмент — тот сервер, с которым
    /// работает всё приложение; адрес у каждого свой.
    private var providerBar: some View {
        HStack(spacing: 12) {
            Picker(String(localized: "Сервер моделей"), selection: Binding(
                get: { settings.configuration.llmProvider },
                set: { settings.configuration.llmProvider = $0 }
            )) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding()
    }

    private var modelsTab: some View {
        VStack(spacing: 0) {
            if model.models.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Моделей нет"), systemImage: "cpu")
                } description: {
                    Text(model.modelsRefreshedAt == nil
                         ? String(localized: "Список ещё не получен — приложение спрашивает LM Studio само, это займёт секунду.")
                         : String(localized: "LM Studio не отдала ни одной модели. Проверьте на вкладке «Подключение», что она запущена и Local Server включён."))
                }
                // Всё оставшееся место — пустому списку: подпись — по центру
                // под сообщениями, а не вместе с ними.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                modelsTable
                modelsFooter
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if tab == 0 {
                    Button {
                        if let item = selectedItem { Task { await model.requestBenchmark(item, app: app) } }
                    } label: {
                        Label(String(localized: "Измерить скорость"), systemImage: "speedometer")
                    }
                    .help(String(localized: "Измерить скорость выбранной модели эмбеддинга"))
                    .disabled(selectedItem?.kind != .embedding || model.benchmarkingModel != nil)
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
                    secondaryButton: .cancel(Text("Отменить")) { model.cancelPendingAction() }
                )
            case .load(let name, let from, let to):
                // Перезагрузка модели — работа LM Studio, а не приложения: она
                // выгрузит модель у всех, кто ею пользуется, и займёт минуты и
                // гигабайты. Такое начинают по ответу человека (правило 4).
                return Alert(
                    title: Text("Перезагрузить «\(name)» с контекстом \(to.plainDigits)?"),
                    message: Text("Сейчас модель загружена с \(from.plainDigits). LM Studio выгрузит её и поднимет заново — это займёт время и больше памяти, а идущие сейчас запросы к ней прервутся.\n\nЕсли максимум окажется слишком тяжёлым, загрузите модель вручную в LM Studio с промежуточным значением."),
                    primaryButton: .default(Text("Перезагрузить")) { model.startLoad(app) },
                    secondaryButton: .cancel(Text("Отменить")) { model.cancelPendingAction() }
                )
            }
        }
    }

    private var selectedItem: LMStudioModel? {
        guard let selectedModel else { return nil }
        return model.models.first { $0.id == selectedModel }
    }

    /// Модель по умолчанию — первое, что видно на экране: она отвечает
    /// на вопрос «чем считается всё, если не указано иное».
    private var defaultModelSection: some View {
        Section {
            Picker(String(localized: "Модель по умолчанию"), selection: Binding(
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
            .disabled(model.embeddingModels.isEmpty)
        } header: {
            SectionHeader(
                String(localized: "Эмбеддинг"),
                help: String(localized: "У коллекции своя модель, привязанная навсегда: эта настройка задаёт лишь то, что подставляется при создании новой. Уже посчитанные векторы она не трогает.")
            )
        } footer: {
            if let measured = settings.configuration.defaultEmbeddingModel
                .flatMap({ model.benchmark(for: $0, server: settings.configuration.llmProvider) }) {
                Text("Измерено: \((measured.textsPerSecond).decimal(1)) текстов/с · размерность \(measured.dimension.plainDigits).")
            } else if model.embeddingModels.isEmpty {
                Text("Список моделей пуст — проверьте соединение с LM Studio ниже.")
            } else {
                Text("Ею создаются коллекции и считаются векторы текстовых запросов, если модель не указана явно.")
            }
        }
    }

    private var lmStudioSection: some View {
        Section {
            // LM Studio выпускается только для Apple Silicon: на Маке
            // с Intel её адрес имеет смысл, только если она на другом компьютере.
            // Условие — во время работы, а не `#if`: строку должен видеть
            // каталог текстов, собираемый на Apple Silicon.
            if LLMProvider.platformDefault == .ollama, settings.configuration.llmProvider == .lmStudio {
                Notice(.info, String(localized: "На Маке с Intel LM Studio не работает. Выберите Ollama или впишите адрес LM Studio на другом компьютере."))
            }
            LabeledContent(String(localized: "Адрес")) {
                TextField(String(localized: "Адрес локального сервера"), text: Binding(
                    get: { settings.configuration.llmBaseURL },
                    set: { settings.configuration.llmBaseURL = $0 }
                ))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                Button(String(localized: "Проверить соединение")) {
                    Task { await model.checkConnection(app) }
                }
                .disabled(model.isChecking)
            }
            LabeledContent(String(localized: "Состояние")) {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                }
                lmStudioStatus
            }
        } header: {
            switch settings.configuration.llmProvider {
            case .lmStudio:
                SectionHeader(
                    String(localized: "LM Studio"),
                    help: String(localized: "По умолчанию http://localhost:1234. Если соединение не устанавливается — запустите LM Studio и включите Local Server в разделе Developer. Список моделей приложение обновляет само: раз в минуту, пока окно активно, и сразу при возврате в приложение. «Проверить соединение» делает больше — выясняет тип моделей, о которых API молчит, пробным запросом.")
                )
            case .ollama:
                SectionHeader(
                    String(localized: "Ollama"),
                    help: String(localized: "По умолчанию http://localhost:11434. Если соединение не устанавливается — запустите Ollama: приложение Ollama или `ollama serve` в терминале. Модели скачиваются в самой Ollama, например `ollama pull nomic-embed-text`; их тип и контекст она сообщает сама. Рабочий контекст задаёт сервер: по умолчанию он зависит от памяти видеокарты, и на Маке с Intel это 4096 токенов; больше — в настройках Ollama или переменной OLLAMA_CONTEXT_LENGTH. Список моделей приложение обновляет само: раз в минуту, пока окно активно, и сразу при возврате в приложение.")
                )
            }
        } footer: {
            switch settings.configuration.llmProvider {
            case .lmStudio:
                Text("Приложение не скачивает и не устанавливает модели — оно использует то, что уже доступно в LM Studio.")
            case .ollama:
                Text("Приложение не скачивает и не устанавливает модели — оно использует то, что уже скачано в Ollama.")
            }
        }
    }

    /// «Пусто» и «не спрашивали» — разные вещи.
    @ViewBuilder
    private var lmStudioStatus: some View {
        if let refreshed = model.modelsRefreshedAt {
            StatusLabel(
                model.models.isEmpty ? .warning : .ok,
                model.models.isEmpty
                    ? String(localized: "отвечает, моделей нет · \(refreshed.formatted(date: .omitted, time: .shortened))")
                    : String(localized: "моделей: \(model.models.count.plainDigits) · \(refreshed.formatted(date: .omitted, time: .shortened))")
            )
            .help(String(localized: "Список обновлён в \(refreshed.formatted(date: .omitted, time: .standard)) — и обновляется сам, пока окно открыто."))
        } else {
            StatusLabel(.off, String(localized: "ещё не спрашивали"))
        }
    }

    /// Таблица, а не карточка на модель: с дюжиной моделей стопка карточек
    /// была выше окна.
    private var modelsTable: some View {
        // Строки — однострочные (v3): то, что стояло второй строкой под
        // именем, — своими колонками.
        Table(model.models, selection: $selectedModel, columnCustomization: $columns) {
            TableColumn(String(localized: "Модель")) { item in
                Text(item.id)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.id)
            }
            .customizationID("model")
            TableColumn(String(localized: "Тип")) { item in
                Picker(String(localized: "Тип"), selection: Binding(
                    get: { item.kind },
                    set: { model.overrideKind(item, to: $0, app: app) }
                )) {
                    ForEach(LMStudioModelKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                // Меню без рамки (v4 B): рамка в каждой строке была тяжёлой.
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                // Откуда тип — подсказкой, а не отдельной колонкой (v3).
                .help(item.kindIsInferred
                      ? String(localized: "Тип определён приложением пробным запросом")
                      : String(localized: "Тип определён по API LM Studio"))
            }
            .width(min: 110, ideal: 140, max: 180)
            .customizationID("kind")
            TableColumn(String(localized: "Скорость")) { item in
                speedCell(item)
            }
            .width(min: 90, ideal: 110, max: 150)
            .alignment(.numeric)
            .customizationID("speed")
            TableColumn(String(localized: "Размерность")) { item in
                Text(model.benchmark(for: item.id, server: settings.configuration.llmProvider).map { $0.dimension.plainDigits } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 130)
            .alignment(.numeric)
            .customizationID("dimension")
            TableColumn(String(localized: "Контекст")) { item in
                // Контекст задаётся при загрузке модели, и по сети его не
                // поменять — только перезагрузкой в LM Studio.
                // Очередь держит группу локальной модели последовательной
                //: перезагрузка может ждать конца идущей работы.
                Text(model.loadingModel == item.id
                     ? (model.loadWaitsInQueue ? String(localized: "ждёт очереди…") : String(localized: "загружается…"))
                     : (item.contextLine ?? "—"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(String(localized: "Потолок — что модель умеет; «загружена с» — с чем её подняли в LM Studio. Порождающие вызовы (чанкинг, переранжирование) упираются во второе. Размер задаётся при загрузке модели в LM Studio."))
            }
            .width(min: 110, ideal: 150, max: 200)
            .customizationID("context")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = model.models.first(where: { $0.id == id }) {
                if item.kind == .embedding {
                    Button(model.benchmark(for: item.id, server: settings.configuration.llmProvider) == nil
                           ? String(localized: "Измерить скорость…")
                           : String(localized: "Измерить заново…")) {
                        Task { await model.requestBenchmark(item, app: app) }
                    }
                    .disabled(model.benchmarkingModel != nil)
                }
                // Перезагрузка — через `lms`, то есть только у LM Studio:
                // контекст Ollama задаётся в её настройках.
                if settings.configuration.llmProvider == .lmStudio,
                   let range = model.reloadableContext(item), model.loadingModel == nil {
                    Button(String(localized: "Перезагрузить с контекстом \(range.to.plainDigits)…")) {
                        model.requestLoad(item)
                    }
                }
                Divider()
                Button(String(localized: "Скопировать имя")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.id, forType: .string)
                }
            }
        }
    }

    private var modelsFooter: some View {
        TableFooter(
            String(localized: "Моделей: \(model.models.count.plainDigits). Тип можно исправить в таблице."),
            help: String(localized: "Тип берётся из ответа API; если API его не сообщает, он определяется пробным запросом к /v1/embeddings. «Реранкинг» ставится только вручную: LM Studio отдаёт переранжировщики обычными чат-моделями, и отличить их запросом нельзя. Помеченные так модели идут первыми в списке для переранжирования в «Умном поиске». Скорость и перезагрузку с большим контекстом — в контекстном меню строки.")
        )
    }

    /// Скорость эмбеддинга — что измерено; батч — в подсказке. Только
    /// у эмбеддинг-моделей: замер идёт через `/v1/embeddings`.
    @ViewBuilder
    private func speedCell(_ item: LMStudioModel) -> some View {
        if model.benchmarkingModel == item.id {
            ProgressView().controlSize(.small)
                .help(String(localized: "измеряется…"))
        } else if item.kind == .embedding, let measured = model.benchmark(for: item.id, server: settings.configuration.llmProvider) {
            Text("\((measured.textsPerSecond).decimal(1)) текстов/с")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(String(localized: "Оптимальный батч: \(measured.optimalBatchSize ?? 0)"))
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
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

    // MARK: - Кэш

    /// the cache is invisible in use, so the only way to know it works is a
    /// section that says how much it holds and how often it answered.
    private var cacheForm: some View {
        Form {
            Section {
                Toggle(String(localized: "Использовать кэш"), isOn: Binding(
                    get: { settings.configuration.embeddingCacheEnabled },
                    set: { settings.configuration.embeddingCacheEnabled = $0 }
                ))
                if let statistics = model.cacheStatistics {
                    LabeledContent(String(localized: "Записей"), value: statistics.entries.formatted())
                    LabeledContent(String(localized: "Размер"), value: statistics.sizeText)
                    LabeledContent(
                        String(localized: "Из кэша за сеанс"),
                        value: statistics.hits + statistics.misses > 0
                            ? String(localized: "\(statistics.hits.formatted()) из \((statistics.hits + statistics.misses).formatted())")
                            : String(localized: "обращений не было")
                    )
                }
                // Предел меняется в «Настройках → Хранение» (v6 A5): одна
                // настройка — одно место. Здесь — значение и путь туда.
                LabeledContent(String(localized: "Предел")) {
                    // Тем же счётом, что поле в Настройках (ГБ = 1024³ байт):
                    // «2 ГБ» там и здесь, а не «2» и «2,15».
                    Text(String(localized: "\((Double(settings.configuration.embeddingCacheLimitBytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(0...2)))) ГБ"))
                    Button(String(localized: "Изменить в Настройках…")) {
                        settingsTab = SettingsWindow.Tab.storage.rawValue
                        openSettings()
                    }
                }
                HStack {
                    Spacer()
                    // Не разрушительная: данные от этого не теряются — теряется
                    // только уже посчитанное, и цена сказана строкой ниже.
                    Button(String(localized: "Очистить кэш")) {
                        Task { await model.clearCache(app) }
                    }
                    .disabled(model.isClearingCache)
                }
            } header: {
                SectionHeader(
                    String(localized: "Кэш эмбеддингов"),
                    help: String(localized: "Вектор уже посчитанного текста берётся отсюда, а не у модели. На результаты не влияет — только на время. При переполнении вытесняются записи, к которым дольше всего не обращались.")
                )
            } footer: {
                Text("После очистки векторы придётся считать заново — коллекции при этом не меняются.")
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshCacheStatistics(app) }
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

