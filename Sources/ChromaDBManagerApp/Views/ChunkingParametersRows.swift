import SwiftUI
import ChromaCore

/// Параметры выбранной стратегии нарезки — одни на редактор источника
/// и на окно пересчёта векторов.
///
/// Окно пересчёта показывало для любой стратегии только размер и единицы:
/// у Adaptive не было ни границ размера, ни чувствительности, ни перекрытия,
/// и клон резался не теми параметрами, которыми резал источник. Теперь
/// строки — те же, что в «Как резать на чанки» у источника.
struct ChunkingParametersRows<LLMExtras: View>: View {
    @Binding var chunking: ChunkingConfiguration
    /// Разделители одной строкой, `\n` — словами.
    @Binding var separatorsText: String
    /// По нему document-based выбирает формат в режиме «авто».
    var fileExtension: String?
    var embeddingModels: [String]
    var embeddingModelDefaultTitle: String
    var chatModels: [String]
    /// Строки LLM-based, которые есть только у источника.
    @ViewBuilder var llmExtras: () -> LLMExtras

    var body: some View {
        switch chunking.strategy {
        case .fixed:
            sizeAndOverlap
        case .recursive:
            sizeAndOverlap
            separatorsField
        case .documentBased:
            documentBasedParameters
        case .hierarchical:
            hierarchicalParameters
        case .semantic:
            semanticParameters
        case .adaptive:
            adaptiveParameters
        case .llmBased:
            llmParameters
        }
    }


    var unitPicker: some View {
        Picker(String(localized: "Единицы"), selection: $chunking.sizeUnit) {
            ForEach(SizeUnit.allCases) { unit in
                Text(unit.title).tag(unit)
            }
        }
    }

    func percentRow(_ title: String, value: Binding<Double>, note: String? = nil) -> some View {
        SliderRow(title, value: value, in: 0...50, step: 5) { percent in
            note.map { "\(Int(percent)) % · \($0)" } ?? "\(Int(percent)) %"
        }
    }

    @ViewBuilder
    var sizeAndOverlap: some View {
        StepperRow("chunk_size", value: $chunking.chunkSize, in: 64...8192, step: 64)
        unitPicker
        percentRow(
            String(localized: "Перекрытие"),
            value: $chunking.overlapPercent,
            note: String(localized: "≈ \(chunking.overlapInCharacters) симв.")
        )
    }

    var separatorsField: some View {
        TextField(String(localized: "Разделители"), text: $separatorsText, prompt: Text("по порядку, через |"))
            .font(.body.monospaced())
            .help(String(localized: "`\\n` — перенос строки, разделитель с пробелом по краю — в кавычках: `\". \"`, `\" \"`. Разбиение идёт по первому разделителю, который даёт куски нужного размера."))
    }

    @ViewBuilder
    var documentBasedParameters: some View {
        Picker(String(localized: "Формат"), selection: $chunking.sourceFormat) {
            ForEach(DocumentSourceFormat.allCases) { format in
                Text(format.title).tag(format)
            }
        }
        .help(chunking.sourceFormat == .auto
              ? String(localized: "Формат определяется по расширению каждого файла: .html — как HTML, файлы кода — как код, остальное — как Markdown.")
              : "")

        let format = DocumentSourceFormat.resolved(
            chunking.sourceFormat,
            fileExtension: fileExtension
        )
        if format == .markdown {
            StepperRow(
                String(localized: "Резать по заголовкам уровня"),
                value: $chunking.splitHeaderLevel, in: 1...6
            ) { "H\($0)" }
        }
        if format == .html {
            CommaListField(
                String(localized: "Теги через запятую"),
                items: $chunking.splitTags,
                clean: { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>/")) }
            )
        }
        if format == .code {
            Picker(String(localized: "Резать по"), selection: $chunking.codeSplitBy) {
                ForEach(CodeSplitTarget.allCases) { target in
                    Text(target.title).tag(target)
                }
            }
            .help(String(localized: "Границы определяются по объявлениям в начале строки — это эвристика, а не разбор языка."))
        }

        StepperRow("max_section_size", value: $chunking.maxSectionSize, in: 128...16384, step: 128)
        unitPicker
        Picker(String(localized: "Крупные секции"), selection: $chunking.oversizedFallback) {
            ForEach(OversizedSectionFallback.allCases) { fallback in
                Text(fallback.title).tag(fallback)
            }
        }
        if chunking.oversizedFallback != .keep {
            fallbackCutting(
                String(localized: "Этим и режется секция, которая не влезла. Перекрытие берётся отсюда обоими откатами; разделители — только Recursive."),
                showsSeparators: chunking.oversizedFallback == .recursive
            )
        }
    }

    /// Разделители и перекрытие показываются там, где они **действуют**
    ///.
    ///
    /// Их читают четыре стратегии — document-based в откате для крупных
    /// секций, hierarchical при разбиении длинной секции, adaptive у каждого
    /// блока и LLM-based при откате, — а поле было только у Recursive.
    @ViewBuilder
    func fallbackCutting(_ note: String, showsSeparators: Bool = true) -> some View {
        if showsSeparators {
            separatorsField
        }
        percentRow(String(localized: "Перекрытие"), value: $chunking.overlapPercent)
            .help(note)
    }

    @ViewBuilder
    var hierarchicalParameters: some View {
        StepperRow(String(localized: "Уровней"), value: $chunking.levels, in: 1...2)
        StepperRow(String(localized: "Родитель"), value: $chunking.parentChunkSize, in: 256...16384, step: 256)
        unitPicker
        percentRow(String(localized: "Перекрытие родителя"), value: $chunking.parentOverlapPercent)
        StepperRow(String(localized: "Ребёнок"), value: $chunking.childChunkSize, in: 64...8192, step: 64)
        percentRow(String(localized: "Перекрытие ребёнка"), value: $chunking.childOverlapPercent)
        fallbackCutting(String(localized: "Раздел длиннее родителя режется на части — по этим разделителям и с этим перекрытием."))
        Text("Родительские и дочерние чанки лежат в одной коллекции: различаются полем chunk_level, ребёнок ссылается на родителя через parent_chunk_id.")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    var semanticParameters: some View {
        Picker(String(localized: "Порог"), selection: $chunking.thresholdMode) {
            ForEach(SemanticThresholdMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        if chunking.thresholdMode == .percentile {
            SliderRow(String(localized: "Перцентиль"), value: $chunking.thresholdValue, in: 50...99, step: 1) {
                "\(Int($0))"
            }
        } else {
            SliderRow(String(localized: "Расстояние"), value: $chunking.thresholdValue, in: 0.01...1, step: 0.01) {
                ($0).decimal(2)
            }
        }
        StepperRow(String(localized: "Окно предложений"), value: $chunking.sentenceBuffer, in: 1...5)
        minMaxSize
        Picker(String(localized: "Модель для предложений"), selection: Binding(
            get: { chunking.sentenceEmbeddingModel ?? "" },
            set: { chunking.sentenceEmbeddingModel = $0.isEmpty ? nil : $0 }
        )) {
            Text(embeddingModelDefaultTitle).tag("")
            ForEach(embeddingModels, id: \.self) { id in
                Text(id).tag(id)
            }
        }
    }

    @ViewBuilder
    var adaptiveParameters: some View {
        StepperRow(String(localized: "Базовый размер"), value: $chunking.baseChunkSize, in: 64...8192, step: 64)
        unitPicker
        minMaxSize
        SliderRow(String(localized: "Чувствительность"), value: $chunking.sensitivity, in: 0...1, step: 0.1) {
            ($0).decimal(1)
        }
        .help(String(localized: "Плотный текст (числа, пунктуация, короткие предложения) режется мельче, разреженный — крупнее. Только эвристики, без модели-классификатора."))
        percentRow(String(localized: "Перекрытие"), value: $chunking.overlapPercent)
        separatorsField
    }

    @ViewBuilder
    var llmParameters: some View {
        Picker(String(localized: "Чат-модель"), selection: Binding(
            get: { chunking.chatModel ?? "" },
            set: { chunking.chatModel = $0.isEmpty ? nil : $0 }
        )) {
            Text("не выбрана").tag("")
            ForEach(chatModels, id: \.self) { id in
                Text(id).tag(id)
            }
        }
        Picker(String(localized: "Гранулярность"), selection: $chunking.granularity) {
            ForEach(LLMGranularity.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        SliderRow("temperature", value: $chunking.temperature, in: 0...1, step: 0.05) {
            ($0).decimal(2)
        }

        // reproducibility outweighs everything else here, so the seed
        // is fixed unless the user deliberately unfixes it.
        Toggle(isOn: Binding(
            get: { chunking.generation.seed != nil },
            set: { on in
                chunking.generation.seed = on ? ChatGenerationSettings.defaultSeed : nil
            }
        )) {
            Text("Фиксированный seed")
            Text(chunking.generation.seed == nil
                 ? "Без фиксированного seed повторная индексация того же файла может дать другие границы чанков."
                 : "Тот же файл при повторном прогоне разобьётся так же — переиндексация не создаёт беспричинных различий.")
        }
        if let seed = chunking.generation.seed {
            LabeledContent("seed") {
                TextField("seed", value: Binding(
                    get: { seed },
                    set: { chunking.generation.seed = $0 }
                ), format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                Button(String(localized: "Случайный")) {
                    chunking.generation.seed = Int.random(in: 1...999_999)
                }
            }
        }

        llmExtras()

        StepperRow("max_chunk_size", value: $chunking.maxChunkSize, in: 128...8192, step: 128)
        unitPicker
        Picker(String(localized: "Если ответ не по формату"), selection: $chunking.onMalformedOutput) {
            ForEach(MalformedOutputPolicy.allCases) { policy in
                Text(policy.title).tag(policy)
            }
        }
        StepperRow(String(localized: "Повторов"), value: $chunking.llmMaxRetries, in: 0...5)
        DecimalStepperRow(String(localized: "Таймаут, с"), value: $chunking.llmTimeout, in: 10...600, step: 10)

        LabeledContent(String(localized: "Шаблон запроса")) {
            TextEditor(text: Binding(
                get: { chunking.effectivePrompt },
                set: { chunking.promptTemplate = $0 }
            ))
            .font(.body.monospaced())
            .textArea()
        }
        .help(String(localized: "{{NUMBERED_TEXT}} подставляется пронумерованными предложениями фрагмента — модель отвечает номерами границ; {{TEXT}} — самим текстом, и тогда фрагменты, которые вернёт модель, сверяются с исходником."))
        HStack {
            Spacer()
            Button(String(localized: "Вернуть шаблон по умолчанию для этого режима")) {
                chunking.promptTemplate = ""
            }
        }
    }

    @ViewBuilder
    var minMaxSize: some View {
        StepperRow("min", value: $chunking.minChunkSize, in: 32...4096, step: 32)
        StepperRow("max", value: $chunking.maxChunkSize, in: 128...16384, step: 128)
    }
}
