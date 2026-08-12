import SwiftUI
import ChromaCore

/// Вкладка «Стенд» экрана «Источники»: как ляжет нарезка — до запуска
/// на настоящем источнике. В базу ничего не пишется.
///
/// Раньше здесь же жили три проверки самих моделей — расчёт вектора, сравнение
/// моделей и близость двух текстов, — и всё это пряталось за тумблером
/// «Показать стенд» внутри одной карточки. Проверки уехали туда, где им место:
/// «Модели» → «Замеры»; тумблер убран — вкладка и есть стенд.
struct TestBenchSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var embeddings: EmbeddingsViewModel
    @StateObject private var model = TestBenchViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if let error = model.errorMessage {
                MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
            }
            previewCard
            HowItWorks(screen: "sources.bench") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Стенд читает файл теми же экстракторами, что и синхронизация, и режет теми же стратегиями. Разница одна: результат никуда не записывается.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Чанк длиннее контекста модели при синхронизации не индексируется вовсе — увидеть это здесь дешевле, чем после прогона на всей папке.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Chunking preview

    /// What the extraction said about the file, **before** anything is indexed
    ///: which extractor ran, what structure it found, what it warns
    /// about. Without this, debugging extraction quality is guesswork.
    @ViewBuilder
    private var extractionCard: some View {
        if let failure = model.previewFailure {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.reason)
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Что делать: \(failure.remedy.title.lowercased()). Тот же файл при синхронизации попадёт в «требуют решения» с этой же причиной.")
                    .font(Theme.Font.micro).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.attention.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let document = model.previewDocument {
            VStack(alignment: .leading, spacing: 5) {
                Text("Извлечение").font(Theme.Font.caption).bold()
                HStack(spacing: 6) {
                    chip("экстрактор: \(document.extractorID) v\(document.extractorVersion)")
                    chip("формат: \(document.containerFormat)")
                    chip("структура: \(document.structureSource.rawValue)")
                    if let pages = document.pageCount { chip("страниц: \(pages)") }
                }
                HStack(spacing: 6) {
                    Text("символов: \(document.plainText.count)").font(Theme.Font.micro).foregroundStyle(.secondary)
                    if !document.parts.isEmpty {
                        Text("· частей: \(document.parts.count)").font(Theme.Font.micro).foregroundStyle(.secondary)
                    }
                    // Written only by extractors that actually looked, so their
                    // absence is «не проверялось», not «нет».
                    if let tables = document.hasTables {
                        Text("· таблицы: \(tables ? "есть" : "нет")").font(Theme.Font.micro).foregroundStyle(.secondary)
                    }
                    if let ocr = document.ocrUsed, ocr {
                        let confidence = document.ocrConfidence.map { " (уверенность \(Int($0 * 100))%)" } ?? ""
                        Text("· распознано OCR\(confidence)").font(Theme.Font.micro).foregroundStyle(.orange)
                    }
                }

                ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                    Text("• " + warning.text)
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if document.structure.isEmpty {
                    Text("Структура не распознана — чанкинг по структуре здесь ничего не даст.")
                        .font(Theme.Font.micro).foregroundStyle(.secondary)
                } else {
                    Text("Распознанная структура").font(Theme.Font.micro).bold()
                    ForEach(Array(document.structure.prefix(20).enumerated()), id: \.offset) { _, node in
                        Text(String(repeating: "    ", count: max(0, node.level - 1)) + "• " + node.title
                             + (node.pageNumber.map { " — с. \($0)" } ?? ""))
                            .font(Theme.Font.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if document.structure.count > 20 {
                        Text("…и ещё \(document.structure.count - 20) заголовков")
                            .font(Theme.Font.micro).foregroundStyle(.secondary)
                    }
                }

                if !document.documentMetadata.isEmpty {
                    Text("Метаданные документа: " + document.documentMetadata
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key) = \($0.value)" }
                        .joined(separator: " · "))
                        .font(Theme.Font.micro).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Строка формы стенда: подпись слева, контрол справа.
    private func benchRow<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.Font.control)
                .frame(width: 160, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.micro)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.Palette.accent.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }

    private var previewCard: some View {
        SectionCard(
            title: String(localized: "Тестовый стенд"),
            subtitle: String(localized: "Посмотреть, как ляжет нарезка, — до запуска на настоящем источнике. В базу ничего не пишется."),
            help: String(localized: "Файл читается теми же экстракторами, что и при синхронизации, и режется той же стратегией. Настройки берутся у выбранного источника: иначе стенд покажет не то, что получится в прогоне.")
        ) {
        VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
            // Подписи одной колонкой слева: у Picker и Stepper своя раскладка
            // подписи, и вперемешку они дают рваный левый край.
            benchRow(String(localized: "Стратегия")) {
                Picker("", selection: $model.configuration.strategy) {
                    ForEach(ChunkStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            if let warning = model.configuration.strategy.costWarning {
                Text(warning).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            benchRow(String(localized: "Размер чанка")) {
                HStack(spacing: 10) {
                    Stepper("\(model.configuration.chunkSize.plainDigits)", value: $model.configuration.chunkSize, in: 64...8192, step: 64)
                        .frame(width: 140)
                    Picker("", selection: $model.configuration.sizeUnit) {
                        ForEach(SizeUnit.allCases) { unit in Text(unit.title).tag(unit) }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            }
            if model.configuration.strategy == .llmBased {
                benchRow(String(localized: "Чат-модель")) {
                    Picker("", selection: Binding(
                        get: { model.configuration.chatModel ?? "" },
                        set: { model.configuration.chatModel = $0.isEmpty ? nil : $0 }
                    )) {
                        Text(String(localized: "не выбрана")).tag("")
                        ForEach(embeddings.chatModels) { item in Text(item.id).tag(item.id) }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                }
            }

            benchRow(String(localized: "Файл")) {
                HStack(spacing: 10) {
                    Button(String(localized: "Загрузить файл…")) { model.loadFileForPreview(app) }
                        .buttonStyle(.chromaNormal)
                    Text(model.previewFileName ?? String(localized: "не выбран — можно вставить текст ниже"))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            // Which source's settings the file is read with. Without this the
            // preview would report «нет текстового слоя» for a scan the user's
            // source recognises, and «экспорт выключен» for a Keynote it opens.
            benchRow(String(localized: "Читать с настройками")) {
                Picker("", selection: $model.previewSourceID) {
                    Text(String(localized: "по умолчанию")).tag(UUID?.none)
                    ForEach(app.settings.configuration.dataSources) { source in
                        Text(source.name).tag(UUID?.some(source.id))
                    }
                }
                .labelsHidden()
                .frame(width: 320)
            }
            Text("Распознавание, экспорт Pages и Keynote, метаданные документа — предпросмотр берёт их у выбранного источника, иначе он покажет не то, что получится при синхронизации.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

            extractionCard

            TextEditor(text: $model.previewText)
                .font(Theme.Font.micro)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            HStack {
                Button(String(localized: "Нарезать")) {
                    Task { await model.preview(app) }
                }
                .buttonStyle(.chromaPrimary)
                .disabled(model.isBusy || model.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let stats = model.previewStats {
                Text(stats).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Seeing this before the sync is the whole point: afterwards the
            // over-long chunk is already in the collection, embedded from its
            // first lines only.
            if model.oversizedChunkCount > 0, let limit = model.previewContextLimit {
                MessageBanner(
                    kind: .error,
                    text: String(localized: "Чанков длиннее контекста модели: \(model.oversizedChunkCount) (лимит \(limit) токенов). При синхронизации такие файлы не индексируются — уменьшите размер чанка.")
                )
            }

            ForEach(Array(model.previewChunks.prefix(30)), id: \.index) { chunk in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("#\(chunk.index)").font(Theme.Font.micro).bold()
                        Text("\(chunk.text.count) симв. · ≈\(chunk.estimatedTokens) ток.")
                            .font(Theme.Font.micro)
                            .foregroundStyle(model.exceedsContext(chunk) ? Color.red : Color.secondary)
                        if model.exceedsContext(chunk) {
                            Text("не влезает в контекст").font(Theme.Font.micro)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        }
                        if chunk.level > 0 {
                            Text("родительский").font(Theme.Font.micro)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        }
                        if let parent = chunk.parentIndex {
                            Text("→ родитель #\(parent)").font(Theme.Font.micro).foregroundStyle(.secondary)
                        }
                        if let note = chunk.note {
                            Text(note).font(Theme.Font.micro).foregroundStyle(.orange)
                        }
                    }
                    // The same placement the chunk will carry into the
                    // collection as `page_number`, `heading_path` and
                    // `slide_number` — visible here, before it is written.
                    if let placement = model.previewPlacements[chunk.index] {
                        Text(model.placementText(placement))
                            .font(Theme.Font.micro).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text(chunk.text)
                        .font(Theme.Font.micro)
                        .lineLimit(4)
                        .copyable(chunk.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if model.previewChunks.count > 30 {
                Text("…и ещё \(model.previewChunks.count - 30) чанков")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }
        }
        }
    }
}

/// Ручные замеры самих моделей: «Модели» → «Замеры».
///
/// Переехали со «Стенда» источников: посчитать вектор, сравнить две модели на
/// одном тексте и померить близость двух текстов — вопросы не о том, как режется
/// папка, а о том, чем считаются векторы. Рядом со средними временами прошлых
/// прогонов они и читаются: те — что было, эти — что прямо сейчас.
struct ModelProbeSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var embeddings: EmbeddingsViewModel
    @StateObject private var model = TestBenchViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            if let error = model.errorMessage {
                MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
            }
            probeCard
            similarityCard
        }
    }

    /// Расчёт вектора и сравнение моделей — об одном тексте, поэтому в одной
    /// карточке: сравнение считает ровно то, что набрано выше.
    private var probeCard: some View {
        SectionCard(
            title: String(localized: "Проверка модели на тексте"),
            subtitle: String(localized: "Сколько времени занимает вектор и какой он размерности — на этой машине, а не в документации."),
            help: String(localized: "Запрос уходит в LM Studio, как и при индексации. Ничего не сохраняется: ни в базу, ни в кэш векторов.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                TextEditor(text: $model.probeText)
                    .font(Theme.Font.body)
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.field)
                            .strokeBorder(Theme.Palette.border, lineWidth: 1)
                    )

                if let result = model.probeResult {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(result.model): размерность \(result.dimension.plainDigits), время \(String(format: "%.3f", result.duration)) с")
                            .font(Theme.Font.caption)
                        Text(result.head.map { String(format: "%.4f", $0) }.joined(separator: ", ") + " …")
                            .font(Theme.Font.mono)
                            .foregroundStyle(Theme.Palette.captionText)
                            .copyable(result.head.map { String($0) }.joined(separator: ", "))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if embeddings.embeddingModels.isEmpty {
                    Text("Список моделей пуст — проверьте соединение с LM Studio на вкладке «Модели».")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                } else {
                    AdvancedSection(place: "models.compare", title: String(localized: "Сравнить несколько моделей")) {
                        ForEach(embeddings.embeddingModels) { item in
                            Toggle(item.id, isOn: Binding(
                                get: { model.comparisonModels.contains(item.id) },
                                set: { isOn in
                                    if isOn { model.comparisonModels.insert(item.id) }
                                    else { model.comparisonModels.remove(item.id) }
                                }
                            ))
                            .font(Theme.Font.control)
                        }
                        Button(String(localized: "Сравнить на тексте выше")) {
                            Task { await model.compare(app) }
                        }
                        .buttonStyle(.chromaNormal)
                        .disabled(model.isBusy || model.comparisonModels.isEmpty)

                        ForEach(model.comparison) { measurement in
                            if let error = measurement.error {
                                Text("• \(measurement.model): \(error)")
                                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("• \(measurement.model): размерность \(measurement.dimension ?? 0), \(String(format: "%.3f", measurement.duration ?? 0)) с")
                                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                            }
                        }
                        if model.comparison.count > 1 {
                            Text("Разные размерности означают, что коллекции под эти модели несовместимы между собой.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button(String(localized: "Посчитать вектор")) {
                        Task { await model.probe(app) }
                    }
                    .buttonStyle(.chromaPrimary)
                    .disabled(model.isBusy)
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
        }
    }

    private var similarityCard: some View {
        SectionCard(
            title: String(localized: "Близость двух текстов"),
            subtitle: String(localized: "Косинусная мера — та же, по которой ищет коллекция с метрикой cosine.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                TextField(String(localized: "Первый текст"), text: $model.firstText)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "Второй текст"), text: $model.secondText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button(String(localized: "Посчитать близость")) {
                        Task { await model.measureSimilarity(app) }
                    }
                    .buttonStyle(.chromaNormal)
                    .disabled(model.isBusy)
                    if let value = model.similarity {
                        Text(String(format: "%.4f", value)).font(Theme.Font.body).bold()
                        Text(value > 0.8
                             ? String(localized: "— очень близко")
                             : (value > 0.5 ? String(localized: "— похоже") : String(localized: "— далеко")))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer()
                }
            }
        }
    }
}
