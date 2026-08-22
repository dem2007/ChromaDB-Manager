import SwiftUI
import ChromaCore

/// The editor for a search profile.
///
/// One screen for the whole pipeline, in the order the pipeline runs. The
/// section forbids scattering these as independent switches across the app: the
/// stages interact, their order changes the answer, and they have to be tuned
/// together to be tuned at all.
///
/// Everything here is free to change at any time. That is the point worth
/// repeating on screen: unlike the model, the metric and the chunking strategy
/// (8.2), none of it touches a stored vector, so trying a setting costs a
/// query and nothing else.
struct SearchProfileSheet: View {
    @Binding var profile: SearchProfile
    /// Модели, предлагаемые для переранжирования: помеченные «Реранкинг»
    /// впереди. Пустой список — LM Studio ещё не спрашивали, и поле
    /// остаётся набираемым, а не блокируется ожиданием.
    let rerankModels: [String]
    /// Из них те, что помечены типом «Реранкинг». Предупреждение о режиме
    /// опирается на тип, а по имени файла — только если тип не проставлен.
    let rerankingTypedIDs: Set<String>
    /// Whether this collection actually has two chunk levels. The hierarchy
    /// settings are shown either way, greyed with the reason: hiding them would
    /// make «почему схлопывание не работает» unanswerable.
    let isHierarchical: Bool
    /// Метрика коллекции: штраф за длину честно считается только на косинусе,
    /// и форма обязана сказать это до нажатия, а не после.
    let metric: DistanceMetric?
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        SheetShell(
            title: String(localized: "Профиль поиска"),
            subtitle: String(localized: "Стадии перечислены в том порядке, в котором выполняются. Коллекция: \(profile.collectionName)."),
            help: String(localized: "Ни одна настройка здесь не требует переэмбеддинга: это параметры запроса, а не свойство данных. Поэтому попробовать любую из них стоит одного запроса и ничего больше — в отличие от модели, метрики и стратегии нарезки, которые меняют сами векторы."),
            width: 720,
            height: 620
        ) {
            unknownSettingsWarning
            identity
            candidates
            sources
            hierarchy
            diversity
            neighbours
            reranking
            marks
        } actions: {
            Button(String(localized: "Отмена"), action: onCancel)
                .buttonStyle(.chromaNormal)
            Button(String(localized: "Сохранить"), action: onSave)
                .buttonStyle(.chromaPrimary)
        }
    }

    // MARK: - Sections

    /// Настройки из файла, которых эта сборка не знает.
    ///
    /// Первой карточкой и оранжевым: это не тонкость настройки, а причина,
    /// по которой профиль ведёт себя не так, как написано в файле. Живой
    /// случай — прогон стенда с порогом текстовой стадии на сборке, где
    /// порога ещё не было: четыре варианта дали числа опорного до третьего
    /// знака, и объяснения этому на экране не было никакого.
    @ViewBuilder
    private var unknownSettingsWarning: some View {
        if !profile.unknownSettings.isEmpty {
            SectionCard(title: String(localized: "Настройки, которых эта сборка не знает")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.unknownSettings.joined(separator: ", "))
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Palette.attention)
                        .textSelection(.enabled)
                    Text(String(localized: "Они записаны в файле профилей, но в поиске не участвуют — и пропадут, как только вы нажмёте «Сохранить». Обычно это значит, что профиль правила сборка поновее: обновите приложение, прежде чем полагаться на эти настройки."))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var identity: some View {
        SectionCard(title: String(localized: "Имя")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(String(localized: "название профиля"), text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                Toggle(String(localized: "Профиль по умолчанию для этой коллекции"), isOn: $profile.isDefault)
                    .toggleStyle(.checkbox)
                    .help(String(localized: "Именно этот профиль применяется к запросам, пока не выбран другой."))
            }
        }
    }

    private var candidates: some View {
        SectionCard(
            title: String(localized: "1. Генерация кандидатов"),
            subtitle: String(localized: "Обязательная стадия. Пул больше n_results запрашивается только тогда, когда дальше есть чему отсеивать: лишние кандидаты меняют выдачу HNSW и даром её не достаются.")
        ) {
            HStack(spacing: 16) {
                Stepper(
                    String(localized: "пул: n_results × \(profile.candidateMultiplier)"),
                    value: $profile.candidateMultiplier, in: 1...20
                )
                .frame(width: 220)
                Stepper(
                    String(localized: "но не меньше \(profile.minimumCandidates)"),
                    value: $profile.minimumCandidates, in: 1...200, step: 5
                )
                .frame(width: 220)
            }

            Divider().padding(.vertical, 4)

            // Длина кандидата. Здесь же, в стадии 1: порядок стадий
            // из E0.1 неизменен, а отсекать и штрафовать надо там, где
            // кандидаты ещё есть — стадии 3–7 не вернут того, чего нет.
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Штраф за длину"), isOn: $profile.lengthPenaltyEnabled)
                    .toggleStyle(.checkbox)
                    .help(String(localized: "Оценка умножается на min(1, длина / цель) в степени. Чанк из одного слова перестаёт обыгрывать абзац."))
                Text(String(localized: "Схожесть меряет совпадение темы, а не полезность: чанк из одного слова «Сервер» отвечает запросу «сервер» дословно, схожесть 1.00. Замер на nomic-embed-text-v1.5: шапка таблицы близка к любому запросу — 0.70 к «сервер», 0.69 к «СКАЛА-Р», 0.74 к «отпуск сотрудника». Штраф ставит содержательные куски вперёд и не стоит ни одного пересчёта векторов."))
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
                if profile.lengthPenaltyEnabled {
                    HStack(spacing: 16) {
                        Stepper(
                            String(localized: "цель: \(profile.lengthTarget) знаков"),
                            value: $profile.lengthTarget, in: 50...4000, step: 50
                        )
                        .frame(width: 220)
                        HStack(spacing: 4) {
                            Text("степень").font(Theme.Font.caption)
                            TextField("", value: $profile.lengthPenaltyPower, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                        .help(String(localized: "0.5 — мягко, 1.0 — вдвое жёстче. Ноль выключает штраф."))
                        Text(lengthExample)
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    if metric != .cosine {
                        Text(String(localized: "Метрика коллекции не даёт схожести — штраф применён не будет, и панель «Как получен этот результат» скажет об этом. Честно домножать можно только косинус."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Stepper(
                    profile.minimumCharacters > 0
                        ? String(localized: "отбрасывать короче \(profile.minimumCharacters) знаков")
                        : String(localized: "не отбрасывать по длине"),
                    value: $profile.minimumCharacters, in: 0...2000, step: 50
                )
                .frame(width: 320)
                .help(String(localized: "Жёсткая отсечка. Выбрасывает и те короткие чанки, которые изредка и есть ответ, — артикул, код ошибки, номер постановления."))
            }
        }
    }

    /// Что штраф делает с тремя длинами — на нынешних параметрах.
    private var lengthExample: String {
        let sample = [30, 150, profile.lengthTarget]
        let parts = sample.map { length -> String in
            let factor = LengthPreference.factor(
                length: length, target: profile.lengthTarget, power: profile.lengthPenaltyPower
            )
            return "\(length): ×\(String(format: "%.2f", factor))"
        }
        return parts.joined(separator: ", ")
    }

    private var sources: some View {
        SectionCard(
            title: String(localized: "1–2. Источники кандидатов и слияние"),
            subtitle: String(localized: "Текстовый поиск отвечает на «найди точный код ошибки», а не на любой запрос. Два источника сливаются рангами (RRF): расстояние и позицию в текстовой выдаче складывать напрямую нельзя.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Векторный поиск"), isOn: $profile.vectorSearchEnabled)
                    .toggleStyle(.checkbox)
                Toggle(String(localized: "Текстовый поиск по содержимому документа"), isOn: $profile.textSearchEnabled)
                    .toggleStyle(.checkbox)

                if !profile.vectorSearchEnabled && !profile.textSearchEnabled {
                    Text(String(localized: "Оба источника выключены — искать будет нечем. Оставьте хотя бы один."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                }
                if !profile.vectorSearchEnabled && profile.textSearchEnabled {
                    Text(String(localized: "Режим «только текстовый поиск»: вектор запроса не считается вовсе."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }

                if profile.textSearchEnabled {
                    HStack(spacing: 16) {
                        weightField(String(localized: "вес вектора"), value: $profile.vectorWeight)
                        weightField(String(localized: "вес текста"), value: $profile.textWeight)
                        HStack(spacing: 4) {
                            Text("rrf_k").font(Theme.Font.caption)
                            TextField("", value: $profile.fusionK, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 60)
                        }
                        .help(String(localized: "Константа RRF: чем меньше, тем сильнее решают первые позиции. По умолчанию 60."))
                    }
                    Toggle(String(localized: "Разбивать запрос на слова"), isOn: $profile.splitQueryIntoWords)
                        .toggleStyle(.checkbox)
                    Text(String(localized: "Разбиение ищет каждое слово отдельно — через $or или перечисление в выражении, смотря что выбрано ниже. Поддержка проверена на установленной версии сервера; целиком — надёжнее и по умолчанию."))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    textSearchLengthField
                    Divider().padding(.vertical, 2)
                    Toggle(String(localized: "Спрашивать одним регулярным выражением"),
                           isOn: $profile.textSearchUsesRegex)
                        .toggleStyle(.checkbox)
                    Text(String(localized: "Иначе каждое слово спрашивается несколькими написаниями через $or — на запросе из четырёх слов это двенадцать подстрочных условий и пять секунд против шестисот миллисекунд у выражения. Выражение к тому же не путает «ё» с «е» и не считает «характеристики» вхождением слова «рис»."))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                queryPrefixField
            }
        }
    }

    /// Порог длины запроса для текстовой стадии.
    ///
    /// Пустое поле значит «без порога» — так вело себя приложение всегда, и
    /// молча менять это на число нельзя. Подпись говорит не про настройку,
    /// а про следствие: на аббревиатуре без текстового поиска не находится
    /// ничего, на длинном вопросе он приносит мусор.
    private var textSearchLengthField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "Только для запросов не длиннее")).font(Theme.Font.caption)
                TextField(
                    String(localized: "без порога"),
                    value: $profile.textSearchMaxWords,
                    format: .number
                )
                .textFieldStyle(.roundedBorder).frame(width: 70)
                Text(String(localized: "слов")).font(Theme.Font.caption)
            }
            Text(String(localized: "Пусто — текстовый поиск работает на любом запросе. На замерах разработчика лучшим порогом оказались пять слов: аббревиатуру «СМЭВ» без текстового поиска не находит вовсе, а длинный вопрос он засоряет. Число подобрано на своём наборе — проверьте на своём."))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Приставка к запросу перед вектором.
    private var queryPrefixField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Приставка к запросу"))
                .font(Theme.Font.caption)
            TextField(String(localized: "без приставки"), text: $profile.queryPrefix, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .font(Theme.Font.monoCell)
                .disabled(!profile.vectorSearchEnabled)
            Text(String(localized: "Дописывается перед текстом запроса **только для вектора** — поиск по словам её не видит. Модели Qwen3-Embedding и nomic обучены на несимметричной паре: документ идёт как есть, запрос — с инструкцией. Пустое поле — прежнее поведение."))
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(String(localized: "Qwen3")) {
                    profile.queryPrefix = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: "
                }
                Button(String(localized: "nomic")) { profile.queryPrefix = "search_query: " }
                Button(String(localized: "Убрать")) { profile.queryPrefix = "" }
                    .disabled(profile.queryPrefix.isEmpty)
            }
            .buttonStyle(.chromaSecondary)
            .disabled(!profile.vectorSearchEnabled)
        }
    }

    private var hierarchy: some View {
        SectionCard(
            title: String(localized: "3, 5. Иерархия: где искать и что возвращать"),
            subtitle: isHierarchical
                ? String(localized: "Смысл стратегии Hierarchical: попадать в мелкий чанк, отвечать крупным.")
                : String(localized: "Коллекция нарезана одним уровнем — эти настройки к ней не применяются и ничего не стоят, включая размер пула.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(String(localized: "Искать по"), selection: $profile.searchLevel) {
                    ForEach(ChunkLevelScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .frame(width: 340)
                Toggle(String(localized: "Схлопывать несколько попаданий из одного раздела в один результат"), isOn: $profile.collapseByParent)
                    .toggleStyle(.checkbox)
                Picker(String(localized: "Возвращать"), selection: $profile.promotion) {
                    ForEach(ParentPromotion.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .frame(width: 340)
            }
            .disabled(!isHierarchical)
            .opacity(isHierarchical ? 1 : 0.55)
        }
    }

    private var diversity: some View {
        SectionCard(
            title: String(localized: "4. Разнообразие (MMR)"),
            subtitle: String(localized: "Отбирает результаты, не похожие друг на друга. Стоит пула векторов; на коллекции, где документы и так разные, только портит ранжирование.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Включить разнообразие"), isOn: $profile.diversityEnabled)
                    .toggleStyle(.checkbox)
                if profile.diversityEnabled {
                    HStack(spacing: 12) {
                        Text(String(localized: "разнообразие"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        Slider(value: $profile.diversityLambda, in: 0...1)
                            .frame(width: 260)
                        Text(String(localized: "точность"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        Text(String(format: "λ = %.2f", profile.diversityLambda))
                            .font(Theme.Font.mono)
                    }
                    Text(String(localized: "λ = 1 — обычное ранжирование, λ = 0 — запрос не учитывается вовсе."))
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                }
            }
        }
    }

    private var neighbours: some View {
        SectionCard(
            title: String(localized: "6. Расширение контекста соседями"),
            subtitle: String(localized: "Присоединяет соседние чанки того же файла — текст вокруг найденного. Соседи не занимают мест в выдаче.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    String(localized: "Присоединять соседей"),
                    isOn: Binding(
                        get: { profile.resolvedContextWindow > 0 },
                        // Turning it on offers 1 — the value E2 names — instead
                        // of asking «сколько» before the user knows what it does.
                        set: { profile.contextWindow = $0 ? SearchProfile.suggestedContextWindow : 0 }
                    )
                )
                .toggleStyle(.checkbox)
                if profile.resolvedContextWindow > 0 {
                    Stepper(
                        String(localized: "по \(profile.resolvedContextWindow) с каждой стороны"),
                        value: Binding(
                            get: { profile.resolvedContextWindow },
                            set: { profile.contextWindow = $0 }
                        ),
                        in: 1...SearchProfile.maximumContextWindow
                    )
                    .frame(width: 260)
                    if isHierarchical && profile.promotion != .child {
                        Text(String(localized: "Внимание: результат поднят к родителю, и его соседи по индексу — это его собственные дети."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    }
                }
            }
        }
    }

    private var marks: some View {
        SectionCard(
            title: String(localized: "8. Ручные пометки"),
            subtitle: String(localized: "Закреплённое человеком поднимается, понижённое и устаревшее опускается. Пометки ставятся у документа и живут в его метаданных."),
            help: String(localized: "Стадия идёт последней — после переранжирования и до усечения: закреплённый документ обязан попасть в выдачу, а не быть срезанным вместе с хвостом. Порядок внутри групп не меняется: пометка говорит «выше» и «ниже», а не «вместо».")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Учитывать пометки"), isOn: $profile.marksEnabled)
                    .toggleStyle(.checkbox)
                Text("Выключите, если пометки нужны только как разметка — для курирования базы и наборов оценки, — а порядок выдачи должен оставаться чисто векторным.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reranking: some View {
        SectionCard(
            title: String(localized: "7. Переранжирование"),
            // Цена у режимов разная: один вызов против вызова на фрагмент.
            // Общая формулировка занижала бы вторую в двадцать раз.
            subtitle: profile.rerankEnabled && profile.rerankMode == .crossEncoder
                ? CrossEncoderReranker.costWarning
                : Reranker.costWarning
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "Включить переранжирование"), isOn: $profile.rerankEnabled)
                    .toggleStyle(.checkbox)
                if profile.rerankEnabled {
                    Picker(String(localized: "Как переранжировать"), selection: $profile.rerankMode) {
                        ForEach(RerankMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text(profile.rerankMode.explanation)
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    // Переранжировщик в режиме чат-схемы — почти наверняка не то,
                    // что человек имел в виду. Формулировка выправлена по живой
                    // проверке: первая редакция обещала, что стадия «будет
                    // падать», а она не падает — Structured Output физически
                    // не даёт модели ответить мимо схемы, и та выдаёт формально
                    // правильные оценки, обученная при этом совсем другому.
                    // Обещать отказ там, где его не будет, — то же самое, что
                    // молчать.
                    if profile.rerankMode == .chatSchema, looksLikeReranker {
                        Text(String(localized: "Похоже, выбран специализированный переранжировщик. Он обучен отвечать «да/нет» про одну пару «запрос — фрагмент», а не оценивать список по схеме. Ответ по схеме он выдаст — Structured Output не оставит ему выбора, — но осмысленность оценок ничем не подтверждена. Надёжнее режим «да/нет»."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    }
                    HStack(spacing: 8) {
                        TextField(String(localized: "id модели"), text: $profile.rerankModel)
                            .textFieldStyle(.roundedBorder).frame(width: 320)
                        if !rerankModels.isEmpty {
                            Menu(String(localized: "Выбрать")) {
                                ForEach(rerankModels, id: \.self) { identifier in
                                    Button(identifier) { profile.rerankModel = identifier }
                                }
                            }
                            .frame(width: 110)
                        }
                    }
                    if profile.rerankModel.isEmpty {
                        Text(String(localized: "Модель не выбрана — стадия не выполнится. Модель для переранжирования выбирается отдельно от модели чанкинга."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    }
                    // Промпт и инструкция — разные поля, и показывается то,
                    // которое в этом режиме действительно применяется. Иначе
                    // человек правит текст, до которого выполнение не доходит
                    //.
                    switch profile.rerankMode {
                    case .chatSchema:
                        Text(String(localized: "Промпт (пусто — используется стандартный)")).font(Theme.Font.caption)
                        TextEditor(text: $profile.rerankPrompt)
                            .font(Theme.Font.mono)
                            .frame(height: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Palette.border))
                        Button(String(localized: "Подставить стандартный промпт")) {
                            profile.rerankPrompt = Reranker.defaultPrompt
                        }
                        .controlSize(.small)
                        .disabled(!profile.rerankPrompt.isEmpty)
                    case .crossEncoder:
                        Text(String(localized: "Описание задачи, строка «Instruct» (пусто — стандартная)")).font(Theme.Font.caption)
                        TextField(String(localized: "Instruct"), text: $profile.rerankInstruction)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.Font.mono)
                        Text(String(localized: "Разметку промпта задаёт сама модель — здесь меняется только описание задачи, одной строкой. На маленькой модели (0.6B) переформулировка меняет мало: замерено на шести фрагментах — стандартная и переписанная под документацию дали одинаковый результат. Если выдача не устраивает, надёжнее взять переранжировщик покрупнее."))
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        Button(String(localized: "Подставить стандартную")) {
                            profile.rerankInstruction = CrossEncoderReranker.defaultInstruction
                        }
                        .controlSize(.small)
                        .disabled(!profile.rerankInstruction.isEmpty)
                    }
                }
            }
        }
    }

    /// Тип, проставленный человеком, — знание; имя файла — догадка, которая
    /// молчит про модель, названную иначе. Сначала знание.
    private var looksLikeReranker: Bool {
        rerankingTypedIDs.contains(profile.rerankModel)
            || profile.rerankModel.lowercased().contains("rerank")
    }

    private func weightField(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title).font(Theme.Font.caption)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 60)
        }
    }
}
