import Foundation

/// The stages every search goes through, in the one order they may go through
/// them.
///
/// The order is not a suggestion. Diversity before promotion to the parent and
/// diversity after it give different answers; expanding context before
/// truncation and after it give different answers. Fixing the order once, here,
/// is what makes the settings mean the same thing every time.
public enum RetrievalStage: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    /// Vector search and/or text search — the only stage that talks to the
    /// collection about relevance.
    case candidates
    /// Several candidate lists become one.
    case fusion
    /// Duplicates and children of one parent become one result.
    case collapse
    /// MMR: results that repeat each other are dropped.
    case diversity
    /// A child chunk is replaced by its parent.
    case promote
    /// Neighbouring chunks are attached.
    case context
    /// A chat model reorders what is left.
    case rerank
    /// Ручные пометки человека двигают список.
    case marks
    /// Cut to `n_results`.
    case truncate

    /// Position in the pipeline. Kept explicit rather than relying on the
    /// declaration order, because a reordering of the enum would otherwise
    /// silently reorder the search.
    public var order: Int {
        switch self {
        case .candidates: return 1
        case .fusion: return 2
        case .collapse: return 3
        case .diversity: return 4
        case .promote: return 5
        case .context: return 6
        case .rerank: return 7
        // Последнее слово перед обрезкой — за человеком: закреплённое им
        // обязано попасть в выдачу, а не быть срезанным вместе с хвостом.
        case .marks: return 8
        case .truncate: return 9
        }
    }

    /// Whether the pipeline can run without it. Only two stages cannot be
    /// switched off: something has to produce candidates, and something has to
    /// cut the list to the requested size.
    public var isOptional: Bool { self != .candidates && self != .truncate }

    public var title: String {
        switch self {
        case .candidates: return String(localized: "Генерация кандидатов")
        case .fusion: return String(localized: "Слияние")
        case .collapse: return String(localized: "Схлопывание")
        case .diversity: return String(localized: "Разнообразие")
        case .promote: return String(localized: "Подъём к родителю")
        case .context: return String(localized: "Расширение контекста")
        case .marks: return String(localized: "Ручные пометки")
        case .rerank: return String(localized: "Переранжирование")
        case .truncate: return String(localized: "Усечение")
        }
    }
}

/// Which chunks a search looks at when the collection has two levels.
///
/// The point of hierarchical chunking is to match on small pieces and answer
/// with large ones. Letting both levels compete shows the same text twice and
/// is the reason the strategy currently costs more than it gives.
public enum ChunkLevelScope: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    /// The small chunks — a precise hit on one thought.
    case children
    /// The large ones, when what is wanted is the section rather than the line.
    case parents
    /// Both, competing with each other.
    case all

    public var title: String {
        switch self {
        case .children: return String(localized: "дочерним чанкам")
        case .parents: return String(localized: "родительским чанкам")
        case .all: return String(localized: "всем чанкам")
        }
    }

    /// The condition this scope adds to the query, or `nil` for «all».
    ///
    /// `chunk_level` is an integer here — 0 for a child, 1 and up for a parent —
    /// because that is what the chunkers write. The specification spells the
    /// value as the string `"child"`; the data does not, and matching the data
    /// is what makes the filter work.
    public var condition: MetadataCondition? {
        switch self {
        case .children: return MetadataCondition(field: "chunk_level", op: .equals, value: "0")
        case .parents: return MetadataCondition(field: "chunk_level", op: .greater, value: "0")
        case .all: return nil
        }
    }
}

/// What a hierarchical search returns once it has found a child.
public enum ParentPromotion: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    /// The matched chunk itself — precise, often too short to be useful.
    case child
    /// The section it belongs to. The default: enough context to be an answer.
    case parent
    /// Both — the child as «найдено», the parent as «контекст».
    case both

    public var title: String {
        switch self {
        case .child: return String(localized: "дочерний чанк")
        case .parent: return String(localized: "родительский чанк")
        case .both: return String(localized: "оба")
        }
    }
}

/// A named set of pipeline settings, attached to a collection.
///
/// Kept locally, **not** in the collection's metadata: these are parameters of
/// a query, not a property of the data. Changing any of them costs nothing and
/// requires no re-embedding — which is exactly what separates them from the
/// model, the metric and the chunking strategy (8.2), and what makes the
/// evaluation stand of D1 affordable.
///
/// New stages add their own fields here with defaults, so a file written by an
/// earlier build keeps decoding: a profile that fails to load would silently
/// turn a tuned search back into the default one.
public struct SearchProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Collections are addressed by name here, as everywhere the app stores
    /// something about one: the UUID changes when a collection is recreated
    ///, and a profile should survive that.
    public var collectionName: String
    /// The profile the collection uses when no other is chosen.
    public var isDefault: Bool

    // MARK: - Stage 1: candidates

    /// How large a pool to ask for, as a multiple of `n_results`.
    ///
    /// Only used when a later stage actually has something to discard: with an
    /// empty pipeline a bigger pool is work whose result is thrown away.
    public var candidateMultiplier: Int
    /// The floor under that pool, so a search for three results still has
    /// something for MMR to choose between.
    public var minimumCandidates: Int

    // MARK: - Stages 1 and 2: two sources of candidates

    /// Vector search. Off only in «только текстовый поиск» — sometimes what is
    /// wanted is literally a string, and computing a vector for it is a waste.
    public var vectorSearchEnabled: Bool
    /// Text search through `where_document: {"$contains": …}`.
    ///
    /// Off by default: it is the answer to «найди точный код ошибки», not to
    /// every query, and a second source changes the ranking of every result.
    public var textSearchEnabled: Bool
    public var vectorWeight: Double
    public var textWeight: Double
    /// `rrf_k` — the constant that flattens the curve near the top.
    public var fusionK: Double
    // MARK: - Stage 1: длина кандидата

    /// Отбрасывать кандидатов короче этого числа знаков. 0 — не отбрасывать.
    ///
    /// Выключено по умолчанию: короткий чанк изредка и есть ответ — артикул,
    /// код ошибки, номер постановления, — и жёсткая отсечка их теряет.
    public var minimumCharacters: Int
    /// Штраф за длину: `схожесть × min(1, длина / цель)^степень`.
    public var lengthPenaltyEnabled: Bool
    /// Длина, начиная с которой штрафа нет вовсе, в знаках.
    public var lengthTarget: Int
    /// Степень: 0.5 — мягко (чанк в 30 знаков теряет две трети оценки),
    /// 1.0 — вдвое жёстче.
    public var lengthPenaltyPower: Double

    /// Whether the query is looked for whole or word by word.
    ///
    /// Приставка к тексту запроса **перед тем, как считать вектор**.
    ///
    /// Модели семейства Qwen3-Embedding и nomic обучены на несимметричной
    /// паре: документ идёт в модель как есть, а запрос — с инструкцией
    /// впереди. Без неё вектор запроса и вектор документа лежат в слегка
    /// разных областях, и близость меряется не совсем та.
    ///
    /// Замер на живой `text-embedding-qwen3-embedding-4b` и коллекции
    /// `base_adaptive`: приставка
    /// `"Instruct: Given a web search query, retrieve relevant passages that
    /// answer the query\nQuery: "` меняет выдачу сильно — из десяти мест
    /// совпадает от нуля до трёх. На запросе «импортозамещение программного
    /// обеспечения» без приставки в тройке таблица ЕСИА и модель угроз,
    /// с приставкой — приказ о стратегии и «цели создания импортозамещённой
    /// ИТ-инфраструктуры ЦОД».
    ///
    /// Приставка живёт **в профиле**, а не в привязке коллекции, именно
    /// затем, чтобы стенд мог сравнить её с пустой на одной и той же базе:
    /// это одно отличие варианта, и пересчитывать ради него ничего не нужно.
    ///
    /// Текстовой половины поиска приставка не касается: там ищутся слова
    /// запроса, а не его вектор.
    public var queryPrefix: String

    /// Whole by default. Word-by-word needs `$or` inside `where_document`, and
    /// 3 says that must be verified against the installed server rather than
    /// assumed.
    public var splitQueryIntoWords: Bool

    // MARK: - Stages 3 and 5: the hierarchy

    /// Which level the search looks at. Ignored on a collection that has only
    /// one level.
    public var searchLevel: ChunkLevelScope
    /// Several children of one parent become one result.
    public var collapseByParent: Bool
    public var promotion: ParentPromotion

    // MARK: - Stage 4: diversity

    /// Whether MMR runs at all.
    ///
    /// Off for a new profile and turned on deliberately: it costs a pool of
    /// vectors, and on a collection whose documents genuinely differ it only
    /// makes the ranking worse.
    public var diversityEnabled: Bool
    /// «точность ↔ разнообразие». 1 is the plain ranking, 0 ignores the query.
    public var diversityLambda: Double

    // MARK: - Stage 7: reranking

    /// Off by default and switched on knowingly: one chat call per query turns
    /// a search of milliseconds into one of seconds (`Reranker.costWarning`).
    public var rerankEnabled: Bool
    /// Chosen apart from the chunking model — the two tasks want different
    /// things, and a source's model has no business deciding how search ranks.
    public var rerankModel: String
    /// Как именно переранжировать: один вызов чат-модели со схемой или
    /// вопрос «подходит?» на каждый фрагмент — так работают специализированные
    /// переранжировщики.
    public var rerankMode: RerankMode
    /// Empty means `Reranker.defaultPrompt`. Editable because what «релевантно»
    /// means depends on the corpus. Относится **только** к режиму `.chatSchema`:
    /// это шаблон целого промпта с подстановками `{query}` и `{documents}`.
    public var rerankPrompt: String
    /// Строка `<Instruct>` для режима `.crossEncoder`, пустая — стандартная
    /// (`CrossEncoderReranker.defaultInstruction`).
    ///
    /// Отдельное поле, а не общее с `rerankPrompt`: у них разный смысл и разный
    /// формат — там шаблон промпта с подстановками, здесь одна строка описания
    /// задачи внутри чужой разметки. Одно поле на двоих означало бы, что после
    /// переключения режима в `<Instruct>` уезжает шаблон с `{documents}`.
    public var rerankInstruction: String

    // MARK: - Stage 8: ручные пометки

    /// Учитывать ли пометки человека при ранжировании.
    ///
    /// Включено: закреплённое поднимается, понижённое и устаревшее опускается.
    /// Выключить это должно быть можно — иначе «почему этот документ первый»
    /// перестало бы иметь ответ в самой выдаче, а пометки нужны и просто как
    /// курирование базы, без влияния на порядок.
    public var marksEnabled: Bool

    // MARK: - Stage 6: neighbours

    /// How many neighbouring chunks to attach on each side, 0 to 3.
    ///
    /// `nil` — nobody has chosen — means **off**, not the «по умолчанию 1» of
    /// Two rules of the section collide here: E0.1 says an untuned profile
    /// behaves exactly like the search of stage 2, and the Definition of Done
    /// asks for that to be provable by test; E2 names 1 as the default. The
    /// guarantee wins over the nicety, and 1 becomes what the setting jumps to
    /// when a user does turn it on.
    ///
    /// Kept optional rather than resolved on save so that «пользователь выбрал
    /// ноль» stays distinguishable from «никто не выбирал».
    public var contextWindow: Int?

    public static let maximumContextWindow = 3

    public init(
        id: UUID = UUID(),
        name: String = String(localized: "По умолчанию"),
        collectionName: String,
        isDefault: Bool = true,
        candidateMultiplier: Int = 5,
        minimumCandidates: Int = 20,
        vectorSearchEnabled: Bool = true,
        textSearchEnabled: Bool = false,
        vectorWeight: Double = 1,
        textWeight: Double = 1,
        fusionK: Double = ReciprocalRankFusion.defaultK,
        splitQueryIntoWords: Bool = false,
        minimumCharacters: Int = 0,
        lengthPenaltyEnabled: Bool = false,
        lengthTarget: Int = 300,
        lengthPenaltyPower: Double = 0.5,
        queryPrefix: String = "",
        searchLevel: ChunkLevelScope = .children,
        collapseByParent: Bool = true,
        promotion: ParentPromotion = .parent,
        diversityEnabled: Bool = false,
        diversityLambda: Double = MaximalMarginalRelevance.defaultLambda,
        rerankEnabled: Bool = false,
        rerankModel: String = "",
        rerankMode: RerankMode = .chatSchema,
        rerankPrompt: String = "",
        rerankInstruction: String = "",
        marksEnabled: Bool = true,
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.collectionName = collectionName
        self.isDefault = isDefault
        self.candidateMultiplier = candidateMultiplier
        self.minimumCandidates = minimumCandidates
        self.vectorSearchEnabled = vectorSearchEnabled
        self.textSearchEnabled = textSearchEnabled
        self.vectorWeight = vectorWeight
        self.textWeight = textWeight
        self.fusionK = fusionK
        self.splitQueryIntoWords = splitQueryIntoWords
        self.minimumCharacters = minimumCharacters
        self.lengthPenaltyEnabled = lengthPenaltyEnabled
        self.lengthTarget = lengthTarget
        self.lengthPenaltyPower = lengthPenaltyPower
        self.queryPrefix = queryPrefix
        self.searchLevel = searchLevel
        self.collapseByParent = collapseByParent
        self.promotion = promotion
        self.marksEnabled = marksEnabled
        self.diversityEnabled = diversityEnabled
        self.diversityLambda = diversityLambda
        self.rerankEnabled = rerankEnabled
        self.rerankModel = rerankModel
        self.rerankMode = rerankMode
        self.rerankPrompt = rerankPrompt
        self.rerankInstruction = rerankInstruction
        self.contextWindow = contextWindow
    }

    /// Every optional stage off — the search of stage 2, exactly.
    ///
    /// What «умный поиск выключён» runs. Not the same as a new profile: a new
    /// one has the hierarchy stages on, because that is what hierarchical
    /// chunking is for.
    public static func plain(collectionName: String, name: String) -> SearchProfile {
        SearchProfile(
            name: name,
            collectionName: collectionName,
            textSearchEnabled: false,
            searchLevel: .all,
            collapseByParent: false,
            promotion: .child,
            diversityEnabled: false,
            rerankEnabled: false,
            // Выключенный умный поиск обязан давать ровно то же, что поиск
            // этапа 2 — в том числе не двигать список пометками.
            marksEnabled: false,
            contextWindow: 0
        )
    }

    /// How many neighbours will actually be attached.
    public var resolvedContextWindow: Int {
        min(max(0, contextWindow ?? 0), SearchProfile.maximumContextWindow)
    }

    /// What the стрелка «включить» should offer first.
    public static let suggestedContextWindow = 1

    // MARK: - Decoding a file written by an earlier build
    //
    // Synthesised `Decodable` requires every non-optional property to be
    // present in the JSON — a default in the memberwise initialiser does
    // nothing for it. So every stage added since would break every profile
    // saved before it: the file stops decoding, the store answers «профилей
    // нет», and a tuned search silently becomes the default one. Found exactly
    // that way, on a file written two commits earlier.

    private enum CodingKeys: String, CodingKey {
        case id, name, collectionName, isDefault
        case candidateMultiplier, minimumCandidates
        case vectorSearchEnabled, textSearchEnabled, vectorWeight, textWeight
        case fusionK, splitQueryIntoWords
        case minimumCharacters, lengthPenaltyEnabled, lengthTarget, lengthPenaltyPower
        case queryPrefix
        case searchLevel, collapseByParent, promotion
        case diversityEnabled, diversityLambda
        case rerankEnabled, rerankModel, rerankMode, rerankPrompt, rerankInstruction
        case marksEnabled
        case contextWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Only the identity is required. Everything else falls back to the
        // value a new profile would have.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? String(localized: "По умолчанию")
        collectionName = try container.decode(String.self, forKey: .collectionName)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? true

        candidateMultiplier = try container.decodeIfPresent(Int.self, forKey: .candidateMultiplier) ?? 5
        minimumCandidates = try container.decodeIfPresent(Int.self, forKey: .minimumCandidates) ?? 20

        vectorSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .vectorSearchEnabled) ?? true
        textSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .textSearchEnabled) ?? false
        vectorWeight = try container.decodeIfPresent(Double.self, forKey: .vectorWeight) ?? 1
        textWeight = try container.decodeIfPresent(Double.self, forKey: .textWeight) ?? 1
        fusionK = try container.decodeIfPresent(Double.self, forKey: .fusionK) ?? ReciprocalRankFusion.defaultK
        splitQueryIntoWords = try container.decodeIfPresent(Bool.self, forKey: .splitQueryIntoWords) ?? false
        // Профили, записанные до, читаются как «длина не учитывается»:
        // молча поменять ранжирование у сохранённого профиля нельзя.
        minimumCharacters = try container.decodeIfPresent(Int.self, forKey: .minimumCharacters) ?? 0
        lengthPenaltyEnabled = try container.decodeIfPresent(Bool.self, forKey: .lengthPenaltyEnabled) ?? false
        lengthTarget = try container.decodeIfPresent(Int.self, forKey: .lengthTarget) ?? 300
        lengthPenaltyPower = try container.decodeIfPresent(Double.self, forKey: .lengthPenaltyPower) ?? 0.5
        queryPrefix = try container.decodeIfPresent(String.self, forKey: .queryPrefix) ?? ""

        searchLevel = try container.decodeIfPresent(ChunkLevelScope.self, forKey: .searchLevel) ?? .children
        collapseByParent = try container.decodeIfPresent(Bool.self, forKey: .collapseByParent) ?? true
        promotion = try container.decodeIfPresent(ParentPromotion.self, forKey: .promotion) ?? .parent

        diversityEnabled = try container.decodeIfPresent(Bool.self, forKey: .diversityEnabled) ?? false
        diversityLambda = try container.decodeIfPresent(Double.self, forKey: .diversityLambda)
            ?? MaximalMarginalRelevance.defaultLambda

        rerankEnabled = try container.decodeIfPresent(Bool.self, forKey: .rerankEnabled) ?? false
        rerankModel = try container.decodeIfPresent(String.self, forKey: .rerankModel) ?? ""
        // Профиль, записанный до появления режима, — это чат-схема: другого
        // тогда не было.
        rerankMode = ((try? container.decodeIfPresent(RerankMode.self, forKey: .rerankMode)) ?? nil) ?? .chatSchema
        rerankPrompt = try container.decodeIfPresent(String.self, forKey: .rerankPrompt) ?? ""
        rerankInstruction = try container.decodeIfPresent(String.self, forKey: .rerankInstruction) ?? ""

        // Профиль, записанный до появления пометок, ведёт себя как новый:
        // пометки учитываются. Иначе человек, поставивший «закрепить», не
        // увидел бы никакого действия — и решил бы, что оно не работает.
        marksEnabled = try container.decodeIfPresent(Bool.self, forKey: .marksEnabled) ?? true
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
    }

    /// Stages this profile asks for, whether or not the collection can provide
    /// them.
    ///
    /// «Просит» and «выполнится» are deliberately separate: the hierarchy
    /// settings are on by default because that is what the strategy is for, and
    /// on a collection cut by any other strategy they must have no effect at
    /// all — including no effect on the size of the candidate pool.
    public var requestedStages: Set<RetrievalStage> {
        var stages: Set<RetrievalStage> = []
        if collapseByParent { stages.insert(.collapse) }
        if promotion != .child { stages.insert(.promote) }
        if diversityEnabled { stages.insert(.diversity) }
        // Two sources have to be merged; one does not.
        if textSearchEnabled && vectorSearchEnabled { stages.insert(.fusion) }
        // A model has to be chosen: «включено, но без модели» is a setting that
        // pretends to work.
        if rerankEnabled && !rerankModel.isEmpty { stages.insert(.rerank) }
        if marksEnabled { stages.insert(.marks) }
        // Only when the window was set by hand. The default depends on the
        // collection and is resolved later, when its shape is known.
        if let contextWindow, contextWindow > 0 { stages.insert(.context) }
        return stages
    }

    /// Текст, который уходит **в модель** за вектором запроса.
    ///
    /// Одно место на всё приложение, и это важнее, чем кажется: живой поиск
    /// считает вектор внутри конвейера, а стенд — заранее, снаружи, и кладёт
    /// его в общий на прогон запас. Разойдись эти два места — стенд сравнивал
    /// бы приставку саму с собой: вариант «с приставкой» брал бы из запаса
    /// вектор, посчитанный без неё, и показывал бы ту же выдачу. Ровно этот
    /// класс поломок ловился в, и, и повторять его не стоит.
    public func embeddedQuery(_ text: String) -> String {
        queryPrefix.isEmpty ? text : queryPrefix + text
    }

    /// How many candidates stage 1 asks the collection for.
    ///
    /// With nothing downstream to discard this is `n_results` and no more. That
    /// is not only an optimisation: asking an HNSW index for a larger pool can
    /// change which neighbours come back at all, and «выключённый конвейер даёт
    /// то же, что поиск этапа 2» has to be true literally.
    public func poolSize(nResults: Int, stages: Set<RetrievalStage>) -> Int {
        let requested = max(1, nResults)
        // Promotion alone changes what a result *is*, not how many there are —
        // it needs no spare candidates. Collapsing does: three children of one
        // parent leave one result where there were three. So does diversity:
        // MMR chooses n out of a pool, and with a pool of n it has nothing to
        // choose between.
        // Fusion needs a pool too: two lists of exactly `n` merge into
        // something shorter than `n` only by accident.
        //
        // Пометки в этот список **не** входят, хотя стадия пометок тоже
        // работает с пулом. Закреплённый документ, не попавший
        // в кандидаты, добирается отдельным запросом по самой пометке —
        // это точнее и дешевле, чем поднимать пул всем поискам подряд:
        // помеченных документов единицы, а пул платят все.
        // Переранжирование и длина — тоже работа с пулом.
        //
        // Rerank без пула переставляет те же `n_results`, которые и так
        // вернула база: нужный чанк, стоявший у вектора на сто тридцать
        // третьем месте, до чат-модели не доезжает никогда. То же у отсечки
        // и штрафа за длину: они отбрасывают и двигают, а брать взамен
        // отброшенного нечего, если пул равен выдаче.
        let discardsByLength = minimumCharacters > 0 || lengthPenaltyEnabled
        guard stages.contains(.collapse) || stages.contains(.diversity)
                || stages.contains(.fusion) || stages.contains(.rerank) || discardsByLength else {
            return requested
        }
        return max(requested, max(minimumCandidates, requested * max(1, candidateMultiplier)))
    }
}
