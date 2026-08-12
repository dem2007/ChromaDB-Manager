import SwiftUI
import ChromaCore

/// Sheet that sets up and runs a re-embedding.
struct ReembeddingSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: ReembeddingViewModel
    @ObservedObject var embeddings: EmbeddingsViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel

    var body: some View {
        SheetShell(
            title: String(localized: "Пересчёт векторов"),
            subtitle: String(localized: "Ход операции будет виден на экране коллекций — окно не блокируется."),
            help: String(localized: "Пересчёт заново считает векторы всех документов коллекции выбранной моделью и с выбранной нарезкой. Это время локальной модели и, в варианте «на месте», необратимая запись поверх существующих векторов — поэтому копия и подтверждение спрашиваются до старта, а не после."),
            width: 660,
            height: 720
        ) {
            if let request = model.request {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let message = model.infoMessage {
                    MessageBanner(kind: .info, text: message) { model.infoMessage = nil }
                }
                current(request)
                modelSection(request)
                chunkingSection(request)
                scenarioSection(request)
                if let checkpoint = model.resumable { resumeSection(checkpoint) }
                backupNotice
                if request.scenario == .inPlace { confirmation(request) }
            }
        } actions: {
            Button(String(localized: "Закрыть")) { model.cancelSetup() }
                .buttonStyle(.chromaNormal)
            if model.resumable != nil {
                Button(String(localized: "Продолжить пересчёт")) {
                    model.start(app, collectionsModel: collectionsModel, resume: true)
                }
                .buttonStyle(.chromaNormal)
            }
            Button(startTitle) {
                model.start(app, collectionsModel: collectionsModel)
            }
            .buttonStyle(.chromaPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(model.request?.problem != nil || !model.confirmationSatisfied)
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

    private var startTitle: String {
        model.request?.scenario == .inPlace ? "Пересчитать на месте" : "Создать клон"
    }

    // MARK: - Sections

    private func current(_ request: ReembeddingRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Коллекция «\(request.collection.name)»").font(Theme.Font.control).bold()
            Text("документов: \(request.collection.documentCount.map(String.init) ?? "?") · модель сейчас: \(request.collection.boundModel ?? "не привязана")\(request.collection.effectiveDimension.map { " · размерность \($0)" } ?? "")")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Векторы, посчитанные разными моделями, несравнимы — поэтому «сменить модель» это не переключатель, а одна из двух операций ниже.")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelSection(_ request: ReembeddingRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Целевая модель").font(Theme.Font.control).bold()
            if embeddings.embeddingModels.isEmpty {
                Text("Список моделей пуст. Проверьте соединение с LM Studio во вкладке «Эмбеддинги».")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Модель", selection: Binding(
                get: { request.targetModel },
                set: { model.modelChanged($0, app: app) }
            )) {
                Text("не выбрана").tag("")
                ForEach(embeddings.embeddingModels) { item in
                    Text(item.id).tag(item.id)
                }
            }
            if let note = model.dimensionNote {
                Text(note).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let dimension = model.targetDimension {
                Text("Размерность модели: \(dimension).")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
            if request.targetModel == request.collection.boundModel {
                Text("Это та же модель, что уже привязана к коллекции. Пересчёт имеет смысл только если вы меняете чанкинг.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chunkingSection(_ request: ReembeddingRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Заново нарезать документы", isOn: Binding(
                get: { request.rechunk },
                set: { model.request?.rechunk = $0 }
            ))
            .font(Theme.Font.control)

            if request.rechunk {
                Picker("Стратегия", selection: Binding(
                    get: { request.chunking.strategy },
                    set: { model.request?.chunking.strategy = $0 }
                )) {
                    ForEach(ChunkStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .frame(maxWidth: 360)

                HStack {
                    Stepper("размер: \(request.chunking.chunkSize)", value: Binding(
                        get: { request.chunking.chunkSize },
                        set: { model.request?.chunking.chunkSize = $0 }
                    ), in: 64...8192, step: 64)
                    .frame(width: 210)
                    Picker("Единицы", selection: Binding(
                        get: { request.chunking.sizeUnit },
                        set: { model.request?.chunking.sizeUnit = $0 }
                    )) {
                        ForEach(SizeUnit.allCases) { unit in Text(unit.title).tag(unit) }
                    }
                    .frame(width: 230)
                }

                if request.chunking.strategy == .llmBased {
                    Picker("Чат-модель", selection: Binding(
                        get: { request.chunking.chatModel ?? "" },
                        set: { model.request?.chunking.chatModel = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("не выбрана").tag("")
                        ForEach(embeddings.chatModels) { item in Text(item.id).tag(item.id) }
                    }
                }
                if let warning = request.chunking.strategy.costWarning {
                    Text(warning).font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Нарезка идёт по тексту, который лежит в коллекции. Если коллекцию наполнял источник, лучше изменить его параметры и синхронизировать заново: тогда файлы читаются с диска, а перекрытие между старыми чанками не попадёт в новые.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scenarioSection(_ request: ReembeddingRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Сценарий").font(Theme.Font.control).bold()
            Picker("Сценарий", selection: Binding(
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

            Text(request.scenario.summary)
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

            if request.scenario == .clone {
                HStack {
                    Text("Новая коллекция")
                    TextField("имя", text: Binding(
                        get: { request.newCollectionName },
                        set: { model.request?.newCollectionName = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                if let problem = CollectionNaming.firstProblem(with: request.newCollectionName) {
                    Text("\(problem) Имя будет приведено к «\(CollectionNaming.sanitize(request.newCollectionName))».")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                }
                // Changing the metric is the same kind of reason to clone as
                // changing the model — a collection's metric cannot be edited
                // in place, so this is the only place it can be chosen.
                HStack {
                    Text("Метрика")
                    Picker("", selection: Binding(
                        get: { request.targetMetric ?? request.collection.space ?? .cosine },
                        set: { model.request?.targetMetric = $0 }
                    )) {
                        ForEach(DistanceMetric.allCases) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    .labelsHidden()
                }
                Text(request.collection.space.map {
                    String(localized: "У исходной коллекции — \($0.shortTitle). По умолчанию клон её наследует.")
                } ?? String(localized: "У исходной коллекции метрика неизвестна; клон будет создан с выбранной."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
    }

    private func resumeSection(_ checkpoint: ReembeddingCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Есть незавершённый пересчёт").font(Theme.Font.control).bold().foregroundStyle(Theme.Palette.attention)
            Text("Модель \(checkpoint.targetModel), обработано \(checkpoint.processed) из \(checkpoint.totalIDs), начат \(checkpoint.startedAt.formatted(date: .abbreviated, time: .shortened)). «Продолжить пересчёт» возьмётся с этого места.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Забыть незавершённый пересчёт") { model.discardCheckpoint(app) }
                .font(Theme.Font.caption).buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var backupNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Резервная копия").font(Theme.Font.control).bold()
            Text(settings.configuration.mode == .localDatabase
                 ? "Перед началом приложение остановит локальный сервер, скопирует папку базы и запустит сервер заново. Без копии операция не начнётся."
                 : "Перед началом документы и метаданные коллекции будут выгружены в JSON в папку резервных копий. Векторы не выгружаются — их и пересчитывают. Без копии операция не начнётся.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmation(_ request: ReembeddingRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Подтверждение").font(Theme.Font.control).bold().foregroundStyle(Theme.Palette.danger)
            Text("Пересчёт на месте перезапишет существующие векторы. Введите имя коллекции «\(request.collection.name)», чтобы подтвердить.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("имя коллекции", text: $model.confirmationText)
                .textFieldStyle(.roundedBorder)
        }
    }

}

/// Progress of a running re-embedding, shown on the collections screen rather
/// than in a modal: the operation restarts the local server, and the user should
/// still be able to look around while it runs.
struct ReembeddingProgressCard: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: ReembeddingViewModel

    var body: some View {
        SectionCard(title: "Пересчёт векторов идёт") {
            VStack(alignment: .leading, spacing: 8) {
                if let request = model.runningRequest {
                    Text("«\(request.collection.name)» → \(request.targetModel) · \(request.scenario.title)")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // progress comes from the queue, the only place it lives.
                // Отдельной вьюхой: очередь сообщает о прогрессе четыре раза
                // в секунду, и тело экрана не должно этого оплачивать.
                QueueProgressRow(titlePrefix: "Пересчёт коллекции")
                if model.isPaused {
                    Text("Пауза — операция ждёт продолжения.").font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                }
                HStack {
                    if model.isPaused {
                        Button("Продолжить") { model.resumeRun(app) }
                    } else {
                        Button("Пауза") { model.pause(app) }
                    }
                    Button("Отменить", role: .destructive) { model.cancel() }
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

/// Result of the last run, shown on the collections screen after the sheet closes.
struct ReembeddingReportCard: View {
    let report: ReembeddingReport

    var body: some View {
        SectionCard(title: "Результат пересчёта") {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.line).font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Проверка: \(report.verification.line)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(report.verification.isClean ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Резервная копия: \(report.backup)")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                if report.scenario == .clone {
                    Text("Исходная коллекция «\(report.sourceCollection)» не изменена — сравните результат и удалите её вручную, когда убедитесь.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
