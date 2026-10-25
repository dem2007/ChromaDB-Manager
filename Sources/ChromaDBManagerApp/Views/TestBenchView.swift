import SwiftUI
import ChromaCore

/// Вкладка «Стенд» экрана «Источники»: как ляжет нарезка — до запуска
/// на настоящем источнике. В базу ничего не пишется.
///
/// Тип А — форма: настройки нарезки, текст, извлечение, чанки, «Как это
/// работает». Проверки самих моделей живут в «Модели» → «Замеры».
struct TestBenchSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var embeddings: EmbeddingsViewModel
    @StateObject private var model = TestBenchViewModel()

    var body: some View {
        Form {
            if let error = model.errorMessage {
                Section {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
            settingsSection
            textSection
            extractionSections
            chunksSection
            Section {
                HowItWorks(screen: "sources.bench", String(localized: "Стенд читает файл теми же экстракторами, что и синхронизация, и режет теми же стратегиями. Разница одна: результат никуда не записывается. Чанк длиннее контекста модели при синхронизации не индексируется вовсе — увидеть это здесь дешевле, чем после прогона на всей папке."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Настройки

    private var settingsSection: some View {
        Section {
            Picker(String(localized: "Стратегия"), selection: $model.configuration.strategy) {
                ForEach(ChunkStrategy.allCases) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            StepperRow(String(localized: "Размер чанка"), value: $model.configuration.chunkSize, in: 64...8192, step: 64)
            Picker(String(localized: "Единицы"), selection: $model.configuration.sizeUnit) {
                ForEach(SizeUnit.allCases) { unit in Text(unit.title).tag(unit) }
            }
            if model.configuration.strategy == .llmBased {
                Picker(String(localized: "Чат-модель"), selection: Binding(
                    get: { model.configuration.chatModel ?? "" },
                    set: { model.configuration.chatModel = $0.isEmpty ? nil : $0 }
                )) {
                    Text(String(localized: "не выбрана")).tag("")
                    ForEach(embeddings.chatModels) { item in Text(item.id).tag(item.id) }
                }
            }
            LabeledContent(String(localized: "Файл")) {
                Text(model.previewFileName ?? String(localized: "не выбран — можно вставить текст ниже"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(String(localized: "Загрузить файл…")) { model.loadFileForPreview(app) }
            }
            // Which source's settings the file is read with. Without this the
            // preview would report «нет текстового слоя» for a scan the user's
            // source recognises, and «экспорт выключен» for a Keynote it opens.
            Picker(String(localized: "Читать с настройками"), selection: $model.previewSourceID) {
                Text(String(localized: "по умолчанию")).tag(UUID?.none)
                ForEach(app.settings.configuration.dataSources) { source in
                    Text(source.name).tag(UUID?.some(source.id))
                }
            }
            .help(String(localized: "Распознавание, экспорт Pages и Keynote, метаданные документа — предпросмотр берёт их у выбранного источника, иначе он покажет не то, что получится при синхронизации."))
        } header: {
            SectionHeader(
                String(localized: "Тестовый стенд"),
                help: String(localized: "Файл читается теми же экстракторами, что и при синхронизации, и режется той же стратегией. Настройки берутся у выбранного источника: иначе стенд покажет не то, что получится в прогоне.")
            )
        } footer: {
            VStack(alignment: .leading) {
                if let warning = model.configuration.strategy.costWarning {
                    Notice(.warning, warning)
                }
                Text("Посмотреть, как ляжет нарезка, — до запуска на настоящем источнике. В базу ничего не пишется.")
            }
        }
    }

    private var textSection: some View {
        Section {
            TextEditor(text: $model.previewText)
                .font(.body.monospaced())
                .textArea()
            HStack {
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(String(localized: "Нарезать")) {
                    Task { await model.preview(app) }
                }
                .disabled(model.isBusy || model.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Текст")
        }
    }

    // MARK: - Извлечение

    /// What the extraction said about the file, **before** anything is indexed
    ///: which extractor ran, what structure it found, what it warns
    /// about. Without this, debugging extraction quality is guesswork.
    @ViewBuilder
    private var extractionSections: some View {
        if let failure = model.previewFailure {
            Section {
                Notice(.warning, failure.reason)
            } header: {
                Text("Извлечение")
            } footer: {
                Text("Что делать: \(failure.remedy.title.lowercased()). Тот же файл при синхронизации попадёт в «требуют решения» с этой же причиной.")
            }
        } else if let document = model.previewDocument {
            Section {
                LabeledContent(String(localized: "Экстрактор"), value: "\(document.extractorID) v\(document.extractorVersion)")
                LabeledContent(String(localized: "Формат"), value: document.containerFormat)
                LabeledContent(String(localized: "Структура"), value: document.structureSource.rawValue)
                if let pages = document.pageCount {
                    LabeledContent(String(localized: "Страниц"), value: pages.plainDigits)
                }
                LabeledContent(String(localized: "Символов"), value: document.plainText.count.plainDigits)
                if !document.parts.isEmpty {
                    LabeledContent(String(localized: "Частей"), value: document.parts.count.plainDigits)
                }
                // Written only by extractors that actually looked, so their
                // absence is «не проверялось», not «нет».
                if let tables = document.hasTables {
                    LabeledContent(String(localized: "Таблицы"), value: tables ? String(localized: "есть") : String(localized: "нет"))
                }
                if let ocr = document.ocrUsed, ocr {
                    LabeledContent(
                        String(localized: "Распознано OCR"),
                        value: document.ocrConfidence.map { String(localized: "уверенность \(Int($0 * 100))%") } ?? String(localized: "да")
                    )
                }
                ForEach(Array(document.documentMetadata.sorted { $0.key < $1.key }), id: \.key) { item in
                    LabeledContent(item.key, value: item.value)
                }
            } header: {
                Text("Извлечение")
            } footer: {
                VStack(alignment: .leading) {
                    ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                        Notice(.warning, warning.text)
                    }
                }
            }

            Section {
                if document.structure.isEmpty {
                    Text("Структура не распознана — чанкинг по структуре здесь ничего не даст.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(document.structure.prefix(20).enumerated()), id: \.offset) { _, node in
                        LabeledContent {
                            if let page = node.pageNumber {
                                Text("с. \(page)")
                            }
                        } label: {
                            // Уровень заголовка — отступом в самой строке.
                            Text(String(repeating: "    ", count: max(0, node.level - 1)) + node.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            } header: {
                Text("Распознанная структура")
            } footer: {
                if document.structure.count > 20 {
                    Text("…и ещё \(document.structure.count - 20) заголовков")
                }
            }
        }
    }

    // MARK: - Чанки

    @ViewBuilder
    private var chunksSection: some View {
        if !model.previewChunks.isEmpty {
            Section {
                ForEach(Array(model.previewChunks.prefix(30)), id: \.index) { chunk in
                    chunkRow(chunk)
                }
            } header: {
                Text("Чанки")
            } footer: {
                VStack(alignment: .leading) {
                    // Seeing this before the sync is the whole point: afterwards
                    // the over-long chunk is already in the collection, embedded
                    // from its first lines only.
                    if model.oversizedChunkCount > 0, let limit = model.previewContextLimit {
                        Notice(.warning, String(localized: "Чанков длиннее контекста модели: \(model.oversizedChunkCount) (лимит \(limit) токенов). При синхронизации такие файлы не индексируются — уменьшите размер чанка."))
                    }
                    if let stats = model.previewStats {
                        Text(stats)
                    }
                    if model.previewChunks.count > 30 {
                        Text("…и ещё \(model.previewChunks.count - 30) чанков")
                    }
                }
            }
        }
    }

    private func chunkRow(_ chunk: TextChunk) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(verbatim: "#\(chunk.index)").bold()
                Text("\(chunk.text.count) симв. · ≈\(chunk.estimatedTokens) ток.")
                    .foregroundStyle(.secondary)
                if chunk.level > 0 {
                    Text("родительский").foregroundStyle(.secondary)
                }
                if let parent = chunk.parentIndex {
                    Text("→ родитель #\(parent)").foregroundStyle(.secondary)
                }
                Spacer()
                if model.exceedsContext(chunk) {
                    StatusLabel(.error, String(localized: "не влезает в контекст"))
                }
            }
            if let note = chunk.note {
                Notice(.warning, note)
            }
            // The same placement the chunk will carry into the collection as
            // `page_number`, `heading_path` and `slide_number` — visible here,
            // before it is written.
            if let placement = model.previewPlacements[chunk.index] {
                Text(model.placementText(placement))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(chunk.text)
                .lineLimit(4)
                .copyable(chunk.text)
        }
    }
}

/// Ручные замеры самих моделей: «Модели» → «Замеры» → «Проверить модель…»
///.
///
/// Посчитать вектор, сравнить две модели на одном тексте и померить близость
/// двух текстов — вопросы не о том, как режется папка, а о том, чем
/// считаются векторы. Листом: это разовая проверка, а не состояние экрана.
struct ModelProbeSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var embeddings: EmbeddingsViewModel
    @StateObject private var model = TestBenchViewModel()
    var close: () -> Void

    var body: some View {
        SheetFrame(width: .wide, height: .tall) {
            if let error = model.errorMessage {
                Section {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
            probeSection
            if !embeddings.embeddingModels.isEmpty { compareSection }
            similaritySection
        } actions: {
            if model.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button(String(localized: "Закрыть"), action: close)
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Расчёт вектора — об одном тексте; сравнение ниже считает ровно его же.
    private var probeSection: some View {
        Section {
            TextEditor(text: $model.probeText)
                .textArea()
            if let result = model.probeResult {
                LabeledContent(String(localized: "Модель"), value: result.model)
                LabeledContent(String(localized: "Размерность"), value: result.dimension.plainDigits)
                LabeledContent(String(localized: "Время"), value: String(localized: "\(result.duration.decimal(3)) с"))
                LabeledContent(String(localized: "Начало вектора")) {
                    Text(result.head.map { String(format: "%.4f", $0) }.joined(separator: ", ") + " …")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .copyable(result.head.map { String($0) }.joined(separator: ", "))
                }
            }
            HStack {
                Spacer()
                // Обычная: синяя — только главная кнопка листа (v4).
                Button(String(localized: "Посчитать вектор")) {
                    Task { await model.probe(app) }
                }
                .disabled(model.isBusy)
            }
        } header: {
            SectionHeader(
                String(localized: "Проверка модели на тексте"),
                help: String(localized: "Запрос уходит в LM Studio, как и при индексации. Ничего не сохраняется: ни в базу, ни в кэш векторов.")
            )
        } footer: {
            if embeddings.embeddingModels.isEmpty {
                Text("Список моделей пуст — проверьте соединение с LM Studio на вкладке «Модели».")
            } else {
                Text("Сколько времени занимает вектор и какой он размерности — на этой машине, а не в документации.")
            }
        }
    }

    private var compareSection: some View {
        Section {
            ForEach(embeddings.embeddingModels) { item in
                Toggle(item.id, isOn: Binding(
                    get: { model.comparisonModels.contains(item.id) },
                    set: { isOn in
                        if isOn { model.comparisonModels.insert(item.id) }
                        else { model.comparisonModels.remove(item.id) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            ForEach(model.comparison) { measurement in
                if let error = measurement.error {
                    LabeledContent(measurement.model) {
                        StatusLabel(.error, error)
                    }
                } else {
                    LabeledContent(
                        measurement.model,
                        value: String(localized: "размерность \(measurement.dimension ?? 0), \((measurement.duration ?? 0).decimal(3)) с")
                    )
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Сравнить на тексте выше")) {
                    Task { await model.compare(app) }
                }
                .disabled(model.isBusy || model.comparisonModels.isEmpty)
            }
        } header: {
            Text("Сравнить несколько моделей")
        } footer: {
            if model.comparison.count > 1 {
                Text("Разные размерности означают, что коллекции под эти модели несовместимы между собой.")
            }
        }
    }

    private var similaritySection: some View {
        Section {
            TextField(String(localized: "Первый текст"), text: $model.firstText)
            TextField(String(localized: "Второй текст"), text: $model.secondText)
            if let value = model.similarity {
                LabeledContent(
                    String(localized: "Близость"),
                    value: (value).decimal(4) + " — " + (value > 0.8
                        ? String(localized: "очень близко")
                        : (value > 0.5 ? String(localized: "похоже") : String(localized: "далеко")))
                )
            }
            HStack {
                Spacer()
                Button(String(localized: "Посчитать близость")) {
                    Task { await model.measureSimilarity(app) }
                }
                .disabled(model.isBusy)
            }
        } header: {
            Text("Близость двух текстов")
        } footer: {
            Text("Косинусная мера — та же, по которой ищет коллекция с метрикой cosine.")
        }
    }
}
