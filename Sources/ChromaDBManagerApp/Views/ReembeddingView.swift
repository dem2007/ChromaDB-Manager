import SwiftUI
import ChromaCore

/// Лист настройки пересчёта векторов.
///
/// Сам пересчёт идёт на экране коллекций, а не в листе: окно не блокируется.
struct ReembeddingSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: ReembeddingViewModel
    @ObservedObject var embeddings: EmbeddingsViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel

    var body: some View {
        SheetFrame(width: .wide, height: .tall) {
            if let request = model.request {
                current(request)
                messages
                modelSection(request)
                chunkingSection(request)
                scenarioSection(request)
                if let checkpoint = model.resumable { resumeSection(checkpoint) }
                backupSection
                if request.scenario == .inPlace { confirmation(request) }
            }
        } actions: {
            Spacer()
            Button(String(localized: "Закрыть")) { model.cancelSetup() }
                .keyboardShortcut(.cancelAction)
            if model.resumable != nil {
                Button(String(localized: "Продолжить пересчёт")) {
                    model.start(app, collectionsModel: collectionsModel, resume: true)
                }
            }
            startButton
        }
        .task {
            model.refreshJournal(app)
            // LM Studio's /v1/models does not report model types, so without a
            // probe every model reads as "unknown" and the picker comes up empty.
            if embeddings.embeddingModels.isEmpty {
                await embeddings.checkConnection(app, probeUnknownModels: true)
            }
        }
    }

    /// Пересчёт на месте перезаписывает векторы — кнопка разрушительная,
    /// Return её не нажимает. Клон ничего не трогает — главная кнопка.
    @ViewBuilder
    private var startButton: some View {
        let disabled = model.request?.problem != nil || !model.confirmationSatisfied
        if model.request?.scenario == .inPlace {
            Button(String(localized: "Пересчитать на месте"), role: .destructive) {
                model.start(app, collectionsModel: collectionsModel)
            }
            .destructiveButtonStyle()
            .disabled(disabled)
        } else {
            Button(String(localized: "Создать клон")) {
                model.start(app, collectionsModel: collectionsModel)
            }
            .primaryButtonStyle()
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
        }
    }

    // MARK: - Sections

    private func current(_ request: ReembeddingRequest) -> some View {
        Section {
            LabeledContent(String(localized: "Коллекция"), value: request.collection.name)
            LabeledContent(
                String(localized: "Документов"),
                value: request.collection.documentCount.map { $0.formatted() } ?? "?"
            )
            LabeledContent(
                String(localized: "Модель сейчас"),
                value: request.collection.boundModel ?? String(localized: "не привязана")
            )
            if let dimension = request.collection.effectiveDimension {
                LabeledContent(String(localized: "Размерность"), value: String(dimension))
            }
        } header: {
            SectionHeader(
                String(localized: "Пересчёт векторов"),
                help: String(localized: "Пересчёт заново считает векторы всех документов коллекции выбранной моделью и с выбранной нарезкой. Это время локальной модели и, в варианте «на месте», необратимая запись поверх существующих векторов — поэтому копия и подтверждение спрашиваются до старта, а не после.")
            )
        } footer: {
            Text("Векторы разных моделей несравнимы, поэтому смена модели — одна из двух операций ниже. Ход пересчёта виден на экране коллекций.")
        }
    }

    @ViewBuilder
    private var messages: some View {
        if model.errorMessage != nil || model.infoMessage != nil {
            Section {
                if let error = model.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.link)
                    }
                }
                if let message = model.infoMessage {
                    HStack {
                        Notice(.info, message)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.infoMessage = nil }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func modelSection(_ request: ReembeddingRequest) -> some View {
        Section {
            Picker(String(localized: "Целевая модель"), selection: Binding(
                get: { request.targetModel },
                set: { model.modelChanged($0, app: app) }
            )) {
                Text(String(localized: "не выбрана")).tag("")
                ForEach(embeddings.embeddingModels) { item in
                    Text(item.id).tag(item.id)
                }
            }
        } footer: {
            if embeddings.embeddingModels.isEmpty {
                Notice(.warning, String(localized: "Список моделей пуст. Проверьте соединение с LM Studio в разделе «Модели»."))
            } else if let note = model.dimensionNote {
                Notice(.warning, note)
            } else if request.targetModel == request.collection.boundModel {
                Notice(.info, String(localized: "Это та же модель, что уже привязана к коллекции. Пересчёт имеет смысл, только если меняется нарезка."))
            } else if let dimension = model.targetDimension {
                Text("Размерность модели: \(dimension).")
            }
        }
    }

    private func chunkingSection(_ request: ReembeddingRequest) -> some View {
        Section {
            Toggle(String(localized: "Заново нарезать документы"), isOn: Binding(
                get: { request.rechunk },
                set: { model.request?.rechunk = $0 }
            ))
            if request.rechunk {
                Picker(String(localized: "Стратегия"), selection: Binding(
                    get: { request.chunking.strategy },
                    set: { model.request?.chunking.strategy = $0 }
                )) {
                    ForEach(ChunkStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                // Все параметры стратегии — те же строки, что у источника
                //: прежде здесь были только размер и единицы.
                ChunkingParametersRows(
                    chunking: Binding(
                        get: { model.request?.chunking ?? request.chunking },
                        set: { model.request?.chunking = $0 }
                    ),
                    separatorsText: Binding(
                        get: { model.separatorsText },
                        set: { text in
                            model.separatorsText = text
                            guard let current = model.request?.chunking.separators else { return }
                            model.request?.chunking.separators = SourcesViewModel.parseSeparators(text, fallback: current)
                        }
                    ),
                    fileExtension: nil,
                    embeddingModels: embeddings.embeddingModels.map(\.id),
                    embeddingModelDefaultTitle: String(localized: "та же, что у коллекции"),
                    chatModels: embeddings.chatModels.map(\.id)
                ) {
                    EmptyView()
                }
            }
        } footer: {
            if request.rechunk {
                VStack(alignment: .leading) {
                    if let problem = request.chunking.problem {
                        Notice(.warning, problem)
                    }
                    if let warning = request.chunking.strategy.costWarning {
                        Notice(.warning, warning)
                    }
                    Text("Нарезка идёт по тексту из коллекции. Если коллекцию наполнял источник, лучше изменить его параметры и синхронизировать заново.")
                        .help(String(localized: "Тогда файлы читаются с диска, а перекрытие между старыми чанками не попадёт в новые."))
                }
            }
        }
    }

    private func scenarioSection(_ request: ReembeddingRequest) -> some View {
        Section {
            Picker(String(localized: "Сценарий"), selection: Binding(
                get: { request.scenario },
                set: {
                    model.request?.scenario = $0
                    model.confirmationText = ""
                }
            )) {
                ForEach(ReembeddingScenario.allCases) { scenario in
                    Text(scenario.title).tag(scenario)
                        // Disabled rather than hidden: the user should see that the
                        // option exists and why it is unavailable here.
                        .disabled(scenario == .inPlace && !model.inPlaceAvailable)
                }
            }
            .pickerStyle(.radioGroup)

            if request.scenario == .clone {
                TextField(String(localized: "Новая коллекция"), text: Binding(
                    get: { request.newCollectionName },
                    set: { model.request?.newCollectionName = $0 }
                ), prompt: Text(String(localized: "имя")))
                // Changing the metric is the same kind of reason to clone as
                // changing the model — a collection's metric cannot be edited
                // in place, so this is the only place it can be chosen.
                Picker(String(localized: "Метрика"), selection: Binding(
                    get: { request.targetMetric ?? request.collection.space ?? .cosine },
                    set: { model.request?.targetMetric = $0 }
                )) {
                    ForEach(DistanceMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading) {
                Text(request.scenario.summary)
                if request.scenario == .clone {
                    if let problem = CollectionNaming.firstProblem(with: request.newCollectionName) {
                        Notice(.warning, String(localized: "\(problem) Имя будет приведено к «\(CollectionNaming.sanitize(request.newCollectionName))»."))
                    }
                    Text(request.collection.space.map {
                        String(localized: "У исходной коллекции — \($0.shortTitle). По умолчанию клон её наследует.")
                    } ?? String(localized: "У исходной коллекции метрика неизвестна; клон будет создан с выбранной."))
                }
            }
        }
    }

    private func resumeSection(_ checkpoint: ReembeddingCheckpoint) -> some View {
        Section {
            StatusLabel(.warning, String(localized: "Есть незавершённый пересчёт"))
            LabeledContent(String(localized: "Модель"), value: checkpoint.targetModel)
            LabeledContent(
                String(localized: "Обработано"),
                value: String(localized: "\(checkpoint.processed) из \(checkpoint.totalIDs)")
            )
            LabeledContent(
                String(localized: "Начат"),
                value: checkpoint.startedAt.formatted(date: .abbreviated, time: .shortened)
            )
            Button(String(localized: "Забыть незавершённый пересчёт")) { model.discardCheckpoint(app) }
                .buttonStyle(.link)
        } footer: {
            Text("«Продолжить пересчёт» возьмётся с этого места.")
        }
    }

    private var backupSection: some View {
        Section {
            Label(
                settings.configuration.mode == .localDatabase
                    ? String(localized: "Копия папки базы")
                    : String(localized: "Выгрузка коллекции в JSON"),
                systemImage: "externaldrive"
            )
        } header: {
            Text("Резервная копия")
        } footer: {
            Text(settings.configuration.mode == .localDatabase
                 ? "Перед началом приложение остановит локальный сервер, скопирует папку базы и запустит сервер заново. Без копии операция не начнётся."
                 : "Перед началом документы и метаданные коллекции будут выгружены в JSON в папку резервных копий. Векторы не выгружаются — их и пересчитывают. Без копии операция не начнётся.")
        }
    }

    private func confirmation(_ request: ReembeddingRequest) -> some View {
        Section {
            TextField(String(localized: "Имя коллекции"), text: $model.confirmationText, prompt: Text(verbatim: request.collection.name))
        } header: {
            Text("Подтверждение")
        } footer: {
            Notice(.warning, String(localized: "Пересчёт на месте перезапишет существующие векторы. Введите имя коллекции «\(request.collection.name)», чтобы подтвердить."))
        }
    }
}

/// Ход идущего пересчёта — строкой над экраном коллекции, а не модальным
/// окном: операция перезапускает локальный сервер, а смотреть по сторонам
/// в это время можно.
struct ReembeddingProgressRow: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: ReembeddingViewModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if let request = model.runningRequest {
                    Label(
                        String(localized: "Пересчёт «\(request.collection.name)» → \(request.targetModel) · \(request.scenario.title)"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer()
                if model.isPaused {
                    Button(String(localized: "Продолжить")) { model.resumeRun(app) }
                } else {
                    Button(String(localized: "Пауза")) { model.pause(app) }
                }
                Button(String(localized: "Отменить"), role: .destructive) { model.cancel() }
            }
            // progress comes from the queue, the only place it lives.
            // Отдельной вьюхой: очередь сообщает о прогрессе четыре раза
            // в секунду, и тело экрана не должно этого оплачивать.
            QueueProgressRow(titlePrefix: QueueMirror.TitlePrefix.recompute)
            if model.isPaused {
                Notice(.info, String(localized: "Пауза — операция ждёт продолжения."))
            }
        }
    }
}

/// Итог последнего пересчёта — над экраном коллекции, после закрытия листа.
struct ReembeddingReportRow: View {
    let report: ReembeddingReport

    var body: some View {
        VStack(alignment: .leading) {
            StatusLabel(report.verification.isClean ? .ok : .warning, report.line)
            Text("Проверка: \(report.verification.line)")
                .foregroundStyle(.secondary)
            Text("Резервная копия: \(report.backup)")
                .foregroundStyle(.secondary)
                .copyable(report.backup)
            if report.scenario == .clone {
                Text("Исходная коллекция «\(report.sourceCollection)» не изменена — сравните результат и удалите её вручную, когда убедитесь.")
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
