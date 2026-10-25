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
        SheetFrame(width: .wide, height: .tall) {
            unknownSettingsWarning
            identity
            candidates
            length
            sources
            queryPrefix
            hierarchy
            diversity
            neighbours
            reranking
            rerankText
            marks
        } actions: {
            Spacer()
            Button(String(localized: "Отменить"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Сохранить"), action: onSave)
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Sections

    /// Настройки из файла, которых эта сборка не знает.
    ///
    /// Первой секцией и предупреждением: это не тонкость настройки, а причина,
    /// по которой профиль ведёт себя не так, как написано в файле. Живой
    /// случай — прогон стенда с порогом текстовой стадии на сборке, где
    /// порога ещё не было: четыре варианта дали числа опорного до третьего
    /// знака, и объяснения этому на экране не было никакого.
    @ViewBuilder
    private var unknownSettingsWarning: some View {
        if !profile.unknownSettings.isEmpty {
            Section {
                Text(profile.unknownSettings.joined(separator: ", "))
                    .font(.body.monospaced())
                    .copyable(profile.unknownSettings.joined(separator: ", "))
            } header: {
                Text("Настройки, которых эта сборка не знает")
            } footer: {
                Notice(.warning, String(localized: "Они записаны в файле профилей, но в поиске не участвуют — и пропадут, как только вы нажмёте «Сохранить». Обычно это значит, что профиль правила сборка поновее: обновите приложение, прежде чем полагаться на эти настройки."))
            }
        }
    }

    private var identity: some View {
        Section {
            TextField(String(localized: "Название"), text: $profile.name, prompt: Text("название профиля"))
            Toggle(String(localized: "Профиль по умолчанию для этой коллекции"), isOn: $profile.isDefault)
                .help(String(localized: "Именно этот профиль применяется к запросам, пока не выбран другой."))
        } header: {
            SectionHeader(
                String(localized: "Профиль поиска"),
                help: String(localized: "Ни одна настройка здесь не требует переэмбеддинга: это параметры запроса, а не свойство данных. Поэтому попробовать любую из них стоит одного запроса и ничего больше — в отличие от модели, метрики и стратегии нарезки, которые меняют сами векторы.")
            )
        } footer: {
            Text("Коллекция «\(profile.collectionName)». Стадии ниже — в том порядке, в котором выполняются.")
        }
    }

    private var candidates: some View {
        Section {
            StepperRow(String(localized: "Пул"), value: $profile.candidateMultiplier, in: 1...20) {
                String(localized: "n_results × \($0)")
            }
            StepperRow(String(localized: "Но не меньше"), value: $profile.minimumCandidates, in: 1...200, step: 5)
        } header: {
            SectionHeader(
                String(localized: "1. Генерация кандидатов"),
                help: String(localized: "Обязательная стадия. Пул больше n_results запрашивается только тогда, когда дальше есть чему отсеивать: лишние кандидаты меняют выдачу HNSW и даром её не достаются.")
            )
        }
    }

    /// Длина кандидата. Здесь же, в стадии 1: порядок стадий
    /// из E0.1 неизменен, а отсекать и штрафовать надо там, где
    /// кандидаты ещё есть — стадии 3–7 не вернут того, чего нет.
    private var length: some View {
        Section {
            Toggle(String(localized: "Штраф за длину"), isOn: $profile.lengthPenaltyEnabled)
                .help(String(localized: "Оценка умножается на min(1, длина / цель) в степени. Чанк из одного слова перестаёт обыгрывать абзац."))
            if profile.lengthPenaltyEnabled {
                StepperRow(String(localized: "Цель, знаков"), value: $profile.lengthTarget, in: 50...4000, step: 50)
                TextField(String(localized: "Степень"), value: $profile.lengthPenaltyPower, format: .number)
                    .help(String(localized: "0.5 — мягко, 1.0 — вдвое жёстче. Ноль выключает штраф."))
                LabeledContent(String(localized: "Множитель по длине"), value: lengthExample)
            }
            StepperRow(String(localized: "Отсечка"), value: $profile.minimumCharacters, in: 0...2000, step: 50) {
                $0 > 0
                    ? String(localized: "отбрасывать короче \($0) знаков")
                    : String(localized: "не отбрасывать по длине")
            }
            .help(String(localized: "Жёсткая отсечка. Выбрасывает и те короткие чанки, которые изредка и есть ответ, — артикул, код ошибки, номер постановления."))
        } header: {
            SectionHeader(
                String(localized: "Длина кандидата"),
                help: String(localized: "Схожесть меряет совпадение темы, а не полезность: чанк из одного слова «Сервер» отвечает запросу «сервер» дословно, схожесть 1.00. Замер на nomic-embed-text-v1.5: шапка таблицы близка к любому запросу — 0.70 к «сервер», 0.69 к «СКАЛА-Р», 0.74 к «отпуск сотрудника». Штраф ставит содержательные куски вперёд и не стоит ни одного пересчёта векторов.")
            )
        } footer: {
            if profile.lengthPenaltyEnabled && metric != .cosine {
                Notice(.warning, String(localized: "Метрика коллекции не даёт схожести — штраф применён не будет, и панель «Как получен этот результат» скажет об этом. Честно домножать можно только косинус."))
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
            return "\(length): ×\((factor).decimal(2))"
        }
        return parts.joined(separator: ", ")
    }

    private var sources: some View {
        Section {
            Toggle(String(localized: "Векторный поиск"), isOn: $profile.vectorSearchEnabled)
            Toggle(String(localized: "Текстовый поиск по содержимому документа"), isOn: $profile.textSearchEnabled)
            if profile.textSearchEnabled {
                TextField(String(localized: "Вес вектора"), value: $profile.vectorWeight, format: .number)
                TextField(String(localized: "Вес текста"), value: $profile.textWeight, format: .number)
                TextField(String(localized: "rrf_k"), value: $profile.fusionK, format: .number)
                    .help(String(localized: "Константа RRF: чем меньше, тем сильнее решают первые позиции. По умолчанию 60."))
                Toggle(String(localized: "Разбивать запрос на слова"), isOn: $profile.splitQueryIntoWords)
                    .help(String(localized: "Разбиение ищет каждое слово отдельно — через $or или перечисление в выражении, смотря что выбрано ниже. Поддержка проверена на установленной версии сервера; целиком — надёжнее и по умолчанию."))
                textSearchLengthField
                Toggle(String(localized: "Спрашивать одним регулярным выражением"),
                       isOn: $profile.textSearchUsesRegex)
                    .help(String(localized: "Иначе каждое слово спрашивается несколькими написаниями через $or — на запросе из четырёх слов это двенадцать подстрочных условий и пять секунд против шестисот миллисекунд у выражения. Выражение к тому же не путает «ё» с «е» и не считает «характеристики» вхождением слова «рис»."))
            }
        } header: {
            SectionHeader(
                String(localized: "1–2. Источники кандидатов и слияние"),
                help: String(localized: "Текстовый поиск отвечает на «найди точный код ошибки», а не на любой запрос. Два источника сливаются рангами (RRF): расстояние и позицию в текстовой выдаче складывать напрямую нельзя.")
            )
        } footer: {
            if !profile.vectorSearchEnabled && !profile.textSearchEnabled {
                Notice(.warning, String(localized: "Оба источника выключены — искать будет нечем. Оставьте хотя бы один."))
            } else if !profile.vectorSearchEnabled {
                Text("Режим «только текстовый поиск»: вектор запроса не считается вовсе.")
            }
        }
    }

    /// Порог длины запроса для текстовой стадии.
    ///
    /// Пустое поле значит «без порога» — так вело себя приложение всегда, и
    /// молча менять это на число нельзя. Подсказка говорит не про настройку,
    /// а про следствие: на аббревиатуре без текстового поиска не находится
    /// ничего, на длинном вопросе он приносит мусор.
    private var textSearchLengthField: some View {
        TextField(
            String(localized: "Только для запросов не длиннее, слов"),
            value: $profile.textSearchMaxWords,
            format: .number,
            prompt: Text("без порога")
        )
        .help(String(localized: "Пусто — текстовый поиск работает на любом запросе. На замерах разработчика лучшим порогом оказались пять слов: аббревиатуру «СМЭВ» без текстового поиска не находит вовсе, а длинный вопрос он засоряет. Число подобрано на своём наборе — проверьте на своём."))
    }

    /// Приставка к запросу перед вектором.
    private var queryPrefix: some View {
        Section {
            TextField(String(localized: "Приставка"), text: $profile.queryPrefix, prompt: Text("без приставки"), axis: .vertical)
                .lineLimit(1...3)
                .font(.body.monospaced())
                // Поле называет заголовок секции; без своей подписи оно
                // занимает строку целиком и пишется слева направо.
                .labelsHidden()
            HStack {
                Button(String(localized: "Qwen3")) {
                    profile.queryPrefix = SearchProfile.qwen3QueryPrefix
                }
                Button(String(localized: "nomic")) { profile.queryPrefix = "search_query: " }
                Spacer()
                Button(String(localized: "Убрать")) { profile.queryPrefix = "" }
                    .disabled(profile.queryPrefix.isEmpty)
            }
        } header: {
            SectionHeader(
                String(localized: "Приставка к запросу"),
                help: String(localized: "Модели Qwen3-Embedding и nomic обучены на несимметричной паре: документ идёт как есть, запрос — с инструкцией. Пустое поле — прежнее поведение.")
            )
        } footer: {
            Text("Дописывается перед текстом запроса **только для вектора** — поиск по словам её не видит.")
        }
        .disabled(!profile.vectorSearchEnabled)
    }

    private var hierarchy: some View {
        Section {
            Picker(String(localized: "Искать по"), selection: $profile.searchLevel) {
                ForEach(ChunkLevelScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            Toggle(String(localized: "Схлопывать несколько попаданий из одного раздела в один результат"), isOn: $profile.collapseByParent)
            Picker(String(localized: "Возвращать"), selection: $profile.promotion) {
                ForEach(ParentPromotion.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } header: {
            Text("3, 5. Иерархия: где искать и что возвращать")
        } footer: {
            // Настройки видны и серыми — с причиной: спрятанные, они оставили
            // бы без ответа «почему схлопывание не работает».
            Text(isHierarchical
                 ? String(localized: "Смысл стратегии Hierarchical: попадать в мелкий чанк, отвечать крупным.")
                 : String(localized: "Коллекция нарезана одним уровнем — эти настройки к ней не применяются и ничего не стоят, включая размер пула."))
        }
        .disabled(!isHierarchical)
    }

    private var diversity: some View {
        Section {
            Toggle(String(localized: "Включить разнообразие"), isOn: $profile.diversityEnabled)
            if profile.diversityEnabled {
                Slider(value: $profile.diversityLambda, in: 0...1) {
                    Text(verbatim: "λ = \(profile.diversityLambda.decimal(2))")
                        .monospacedDigit()
                } minimumValueLabel: {
                    Text("разнообразие")
                } maximumValueLabel: {
                    Text("точность")
                }
            }
        } header: {
            SectionHeader(
                String(localized: "4. Разнообразие (MMR)"),
                help: String(localized: "Отбирает результаты, не похожие друг на друга. Стоит пула векторов; на коллекции, где документы и так разные, только портит ранжирование.")
            )
        } footer: {
            if profile.diversityEnabled {
                Text("λ = 1 — обычное ранжирование, λ = 0 — запрос не учитывается вовсе.")
            }
        }
    }

    private var neighbours: some View {
        Section {
            Toggle(
                String(localized: "Присоединять соседей"),
                isOn: Binding(
                    get: { profile.resolvedContextWindow > 0 },
                    // Turning it on offers 1 — the value E2 names — instead
                    // of asking «сколько» before the user knows what it does.
                    set: { profile.contextWindow = $0 ? SearchProfile.suggestedContextWindow : 0 }
                )
            )
            if profile.resolvedContextWindow > 0 {
                StepperRow(
                    String(localized: "С каждой стороны"),
                    value: Binding(
                        get: { profile.resolvedContextWindow },
                        set: { profile.contextWindow = $0 }
                    ),
                    in: 1...SearchProfile.maximumContextWindow
                )
            }
        } header: {
            SectionHeader(
                String(localized: "6. Расширение контекста соседями"),
                help: String(localized: "Присоединяет соседние чанки того же файла — текст вокруг найденного. Соседи не занимают мест в выдаче.")
            )
        } footer: {
            if profile.resolvedContextWindow > 0 && isHierarchical && profile.promotion != .child {
                Notice(.warning, String(localized: "Результат поднят к родителю, и его соседи по индексу — это его собственные дети."))
            }
        }
    }

    private var marks: some View {
        Section {
            Toggle(String(localized: "Учитывать пометки"), isOn: $profile.marksEnabled)
        } header: {
            SectionHeader(
                String(localized: "8. Ручные пометки"),
                help: String(localized: "Стадия идёт последней — после переранжирования и до усечения: закреплённый документ обязан попасть в выдачу, а не быть срезанным вместе с хвостом. Порядок внутри групп не меняется: пометка говорит «выше» и «ниже», а не «вместо».")
            )
        } footer: {
            Text("Закреплённое человеком поднимается, понижённое и устаревшее опускается. Выключите, если пометки нужны только как разметка, а порядок выдачи должен оставаться чисто векторным.")
        }
    }

    private var reranking: some View {
        Section {
            Toggle(String(localized: "Включить переранжирование"), isOn: $profile.rerankEnabled)
            if profile.rerankEnabled {
                Picker(String(localized: "Как переранжировать"), selection: $profile.rerankMode) {
                    ForEach(RerankMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                LabeledContent(String(localized: "Модель")) {
                    HStack {
                        TextField(String(localized: "Модель"), text: $profile.rerankModel, prompt: Text("id модели"))
                            .labelsHidden()
                        if !rerankModels.isEmpty {
                            Menu(String(localized: "Выбрать")) {
                                ForEach(rerankModels, id: \.self) { identifier in
                                    Button(identifier) { profile.rerankModel = identifier }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
                // Сколько кандидатов показать. Не спрятано в код:
                // на замере треть выигрыша пришла из хвоста пула, то есть
                // с мест, куда двадцатка не достаёт.
                StepperRow(
                    String(localized: "Кандидатов переранжировщику"),
                    value: $profile.rerankCandidates,
                    // Шаг пять — и пол пять, а не два: с двойки лестница
                    // вела в 7, 12, 17, и вернуться к умолчанию в двадцать
                    // было нечем. Ниже пятёрки настройка всё равно
                    // бессмысленна, а от двух конвейер защищён сам.
                    in: 5...Reranker.candidateCeiling, step: 5
                )
                .help(profile.rerankMode == .crossEncoder
                      ? String(localized: "Столько же будет вызовов модели на каждый запрос — вдвое больше кандидатов означает вдвое более долгий поиск.")
                      : String(localized: "Все они уходят в один промпт: длинный список и медленнее, и хуже — модель перестаёт замечать хвост."))
            }
        } header: {
            Text("7. Переранжирование")
        } footer: {
            VStack(alignment: .leading) {
                // Цена у режимов разная: один вызов против вызова на фрагмент.
                // Общая формулировка занижала бы вторую в двадцать раз.
                Text(profile.rerankEnabled && profile.rerankMode == .crossEncoder
                     ? CrossEncoderReranker.costWarning(candidates: profile.rerankCandidates)
                     : Reranker.costWarning)
                if profile.rerankEnabled {
                    Text(profile.rerankMode.explanation)
                    // Переранжировщик в режиме чат-схемы — почти наверняка не то,
                    // что человек имел в виду. Формулировка выправлена по живой
                    // проверке: первая редакция обещала, что стадия «будет
                    // падать», а она не падает — Structured Output физически
                    // не даёт модели ответить мимо схемы, и та выдаёт формально
                    // правильные оценки, обученная при этом совсем другому.
                    // Обещать отказ там, где его не будет, — то же самое, что
                    // молчать.
                    if profile.rerankMode == .chatSchema, looksLikeReranker {
                        Notice(.warning, String(localized: "Похоже, выбран специализированный переранжировщик. Он обучен отвечать «да/нет» про одну пару «запрос — фрагмент», а не оценивать список по схеме. Ответ по схеме он выдаст — Structured Output не оставит ему выбора, — но осмысленность оценок ничем не подтверждена. Надёжнее режим «да/нет»."))
                    }
                    if profile.rerankModel.isEmpty {
                        Notice(.warning, String(localized: "Модель не выбрана — стадия не выполнится. Модель для переранжирования выбирается отдельно от модели чанкинга."))
                    }
                }
            }
        }
    }

    /// Промпт и инструкция — разные поля, и показывается то, которое в этом
    /// режиме действительно применяется. Иначе человек правит текст, до
    /// которого выполнение не доходит.
    @ViewBuilder
    private var rerankText: some View {
        if profile.rerankEnabled {
            switch profile.rerankMode {
            case .chatSchema:
                Section {
                    TextEditor(text: $profile.rerankPrompt)
                        .font(.body.monospaced())
                        .textArea()
                    Button(String(localized: "Подставить стандартный промпт")) {
                        profile.rerankPrompt = Reranker.defaultPrompt
                    }
                    .disabled(!profile.rerankPrompt.isEmpty)
                } header: {
                    Text("Промпт переранжирования")
                } footer: {
                    Text("Пусто — используется стандартный.")
                }
            case .crossEncoder:
                Section {
                    TextField(String(localized: "Instruct"), text: $profile.rerankInstruction, prompt: Text("стандартная"))
                        .font(.body.monospaced())
                        .labelsHidden()
                    Button(String(localized: "Подставить стандартную")) {
                        profile.rerankInstruction = CrossEncoderReranker.defaultInstruction
                    }
                    .disabled(!profile.rerankInstruction.isEmpty)
                } header: {
                    SectionHeader(
                        String(localized: "Описание задачи"),
                        help: String(localized: "Разметку промпта задаёт сама модель — здесь меняется только описание задачи, одной строкой. На маленькой модели (0.6B) переформулировка меняет мало: замерено на шести фрагментах — стандартная и переписанная под документацию дали одинаковый результат. Если выдача не устраивает, надёжнее взять переранжировщик покрупнее.")
                    )
                } footer: {
                    Text("Строка «Instruct». Пусто — стандартная.")
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
}
