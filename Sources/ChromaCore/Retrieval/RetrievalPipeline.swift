import Foundation

/// What the pipeline needs from a database — nothing more.
///
/// A protocol rather than the concrete client so that the stages can be tested
/// against a collection whose contents the test dictates: the behaviour worth
/// testing here is «три дочерних чанка одного родителя дают один результат»,
/// and provoking that against a live server would mean building a corpus first.
public protocol RetrievalDatabase: Sendable {
    func query(
        collectionID: String,
        embedding: [Double],
        nResults: Int,
        filter: DocumentFilter?,
        includeEmbeddings: Bool
    ) async throws -> [QueryHit]

    /// Documents by explicit id — the parents of the children that matched.
    ///
    /// By id and never by a `where` on `parent_chunk_id`: the ids are already
    /// known, and a filter would fetch whatever else happened to share the
    /// value.
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord]

    /// Documents matching a filter — one request for a whole page of
    /// neighbours.
    func documents(collectionID: String, matching filter: DocumentFilter, limit: Int) async throws -> [DocumentRecord]

    /// Whether the collection holds at least one document matching — one
    /// request, `limit: 1`, nothing included. Used to establish shape without
    /// sampling.
    func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool
}

// No default implementations on purpose: a conformer that quietly answered
// «нет» to `anyDocument` would turn every collection flat and take the
// hierarchy stages off without a word.

extension ChromaClient: RetrievalDatabase {
    public func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] {
        try await getDocuments(collectionID: collectionID, limit: ids.count, ids: ids)
    }

    public func documents(
        collectionID: String, matching filter: DocumentFilter, limit: Int
    ) async throws -> [DocumentRecord] {
        try await getDocuments(collectionID: collectionID, limit: limit, filter: filter)
    }

    public func anyDocument(collectionID: String, matching filter: DocumentFilter) async throws -> Bool {
        try await !getDocuments(collectionID: collectionID, limit: 1, filter: filter).isEmpty
    }
}

/// One search, as it was asked for.
public struct RetrievalRequest: Sendable {
    public var text: String
    public var collectionID: String
    public var collectionName: String
    public var nResults: Int
    /// The browser's filter, when the user asked for it to narrow the search
    /// too.
    public var filter: DocumentFilter?
    /// How the collection measures distance. Needed by MMR, which has to turn
    /// a distance into a relevance — and can only do that honestly for a metric
    /// with a bounded scale.
    public var metric: DistanceMetric?

    public init(
        text: String,
        collectionID: String,
        collectionName: String,
        nResults: Int = 5,
        filter: DocumentFilter? = nil,
        metric: DistanceMetric? = nil
    ) {
        self.text = text
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.nResults = nResults
        self.filter = filter
        self.metric = metric
    }
}

/// Where a candidate came from.
public enum CandidateSource: String, Codable, Sendable {
    case vector
    case text

    public var title: String {
        switch self {
        case .vector: return String(localized: "векторный поиск")
        case .text: return String(localized: "текстовый поиск")
        }
    }
}

/// Which list a candidate came from and where it stood in it.
///
/// The position matters as much as the source: «нашёл текстовый поиск» explains
/// little, «нашёл текстовый поиск, первым, а вектор не нашёл вовсе» explains the
/// result. E0.4 asks for exactly this pair.
public struct SourcePlacement: Hashable, Sendable {
    public let source: CandidateSource
    /// 1-based, as the source itself ranked it.
    public let position: Int

    public init(source: CandidateSource, position: Int) {
        self.source = source
        self.position = position
    }

    public var line: String {
        String(localized: "\(source.title), позиция \(position)")
    }
}

/// What a row in the result list is.
public enum HitRole: String, Codable, Sendable {
    /// The chunk the query matched.
    case match
    /// Text attached around a match so the answer is readable — a parent, or
    /// later a neighbour. Never counted against `n_results`: context the
    /// user did not ask for must not push out a result they did.
    case context
}

/// Why a piece of context is attached — the card reads differently for each.
public enum ContextKind: String, Codable, Sendable {
    /// The section the matched chunk belongs to («оба»).
    case parent
    /// A chunk that stood next to the match in the same file.
    case neighbour
}

/// One result, carrying what the stages did to it.
///
/// Not `QueryHit`: by the end of the pipeline a result may be a parent standing
/// in for its children, may have absorbed siblings, and may have come from two
/// sources at once. A screen that shows only the distance would be hiding the
/// part the user needs to trust the answer.
public struct RetrievalHit: Identifiable, Hashable, Sendable {
    public let id: String
    public var document: String?
    public var metadata: ChromaMetadata?
    /// Distance as the collection reported it. Stays attached to the chunk that
    /// was actually matched, even after the result has been replaced by its
    /// parent — ranking is by the match, not by the context around it.
    public var distance: Double?
    public var sources: [CandidateSource]
    /// Where each source ranked this candidate before the stages rearranged
    /// them. Empty on a context row, which no source ever ranked.
    public var placements: [SourcePlacement]
    public var role: HitRole
    /// How many further chunks of the same parent matched and were folded into
    /// this one. Zero when nothing was collapsed.
    public var collapsed: Int
    /// Set on a context row: what kind of context it is.
    public var contextKind: ContextKind?
    /// The chunk that actually matched, when this result is standing in for it.
    ///
    /// Set by promotion: the result then *is* the parent — its id, its text,
    /// its metadata — and this is what the query hit. Without it the card would
    /// have to choose between showing the child's id beside the parent's text
    /// (self-contradictory) and losing which chunk matched (unexplainable).
    public var matchedChunkID: String?
    /// Text attached to this result rather than competing with it.
    public var context: [RetrievalHit]
    /// The candidate's vector, carried only while MMR needs it. Never
    /// shown and never stored — a page of embeddings is megabytes.
    public var embedding: [Double]?
    /// Оценка, с которой кандидат идёт дальше по конвейеру.
    ///
    /// `nil` значит «считайте по расстоянию», как было всегда. Заполняется
    /// там, где расстояние перестаёт быть всей правдой о полезности, —
    /// сейчас это штраф за длину.
    ///
    /// Без этого поля штраф двигал **только порядок массива**, а первая же
    /// стадия, которая считает релевантность сама, возвращала всё назад:
    /// MMR берёт `1 - расстояние` и переупорядочивает пул по нему. Живой
    /// замер: у профиля с разнообразием выдача со штрафом и без совпадала
    /// до последнего идентификатора.
    public var relevance: Double?
    /// Коллекция, из которой пришёл результат.
    ///
    /// `nil` у обычного поиска: там коллекция одна и известна спрашивающему.
    /// Заполняется поиском по нескольким коллекциям — без этого выдача
    /// становится списком без ответа на вопрос «а это откуда».
    public var collectionName: String?

    public init(
        id: String,
        document: String?,
        metadata: ChromaMetadata?,
        distance: Double?,
        sources: [CandidateSource] = [.vector],
        placements: [SourcePlacement] = [],
        role: HitRole = .match,
        collapsed: Int = 0,
        contextKind: ContextKind? = nil,
        matchedChunkID: String? = nil,
        context: [RetrievalHit] = [],
        embedding: [Double]? = nil,
        collectionName: String? = nil
    ) {
        self.id = id
        self.document = document
        self.metadata = metadata
        self.distance = distance
        self.sources = sources
        self.placements = placements
        self.role = role
        self.collapsed = collapsed
        self.contextKind = contextKind
        self.matchedChunkID = matchedChunkID
        self.context = context
        self.embedding = embedding
        self.collectionName = collectionName
    }

    public init(_ hit: QueryHit, source: CandidateSource = .vector, position: Int? = nil) {
        self.init(
            id: hit.id, document: hit.document, metadata: hit.metadata,
            distance: hit.distance, sources: [source],
            placements: position.map { [SourcePlacement(source: source, position: $0)] } ?? [],
            embedding: hit.embedding
        )
    }

    /// «нашёл векторный поиск, позиция 3 · текстовый поиск, позиция 1» — the
    /// line the diagnostics panel puts under a result.
    public var originNote: String? {
        guard !placements.isEmpty else { return nil }
        return placements.map(\.line).joined(separator: " · ")
    }

    /// Where this chunk sits in its file — what neighbours are found by.
    public var chunkIndex: Int? {
        guard case .int(let value)? = metadata?["chunk_index"] else { return nil }
        return value
    }

    public var sourceFile: String? {
        guard case .string(let value)? = metadata?["source_file"], !value.isEmpty else { return nil }
        return value
    }

    /// The parent this chunk belongs to, when it is a child of one.
    public var parentChunkID: String? {
        guard case .string(let value)? = metadata?["parent_chunk_id"], !value.isEmpty else { return nil }
        return value
    }

    /// «ещё 3 совпадения в этом разделе» — shown on the card, because a result
    /// that silently swallowed three others is a result the user is entitled to
    /// know about.
    public var collapsedNote: String? {
        guard collapsed > 0 else { return nil }
        return String(localized: "ещё \(collapsed) \(RetrievalHit.matchesWord(collapsed)) в этом разделе")
    }

    static func matchesWord(_ count: Int) -> String {
        RussianCount.word(count, "совпадение", "совпадения", "совпадений")
    }

    /// The shape the browser already knows how to draw.
    public var queryHit: QueryHit {
        QueryHit(id: id, document: document, metadata: metadata, distance: distance)
    }
}

/// What each stage did.
///
/// Collected always, not only when the panel is open: a user reporting «поиск
/// стал хуже» is describing a query that has already happened, and asking them
/// to turn on diagnostics and do it again is asking them to reproduce something
/// they cannot see.
public struct RetrievalDiagnostics: Sendable {
    public struct StageReport: Identifiable, Sendable {
        /// What became of a stage. «Выключено» and «не выполнено» are different
        /// news and used to print the same word: настроенное переранжирование,
        /// упавшее на ответе модели, выглядело выключенным, и жалоба «настройка
        /// не сработала» становилась неразрешимой — ровно та задача, ради
        /// которой панель E0.4 и существует.
        public enum Outcome: Sendable {
            case ran
            /// The profile did not ask for it.
            case skipped
            /// It was asked for, it started, and it did not finish.
            case failed

            public var title: String {
                switch self {
                case .ran: return String(localized: "выполнено")
                case .skipped: return String(localized: "выключено")
                case .failed: return String(localized: "не выполнено")
                }
            }
        }

        public var id: String { stage.rawValue }
        public let stage: RetrievalStage
        public let outcome: Outcome
        public let inputCount: Int
        public let outputCount: Int
        public let duration: TimeInterval
        /// Why this stage did what it did, in one line.
        public let note: String?

        /// True only for a stage that actually did its work.
        public var ran: Bool { outcome == .ran }
        /// True for a stage that was asked for and broke — the case worth a
        /// colour of its own on screen.
        public var failed: Bool { outcome == .failed }

        public init(
            stage: RetrievalStage, outcome: Outcome, inputCount: Int, outputCount: Int,
            duration: TimeInterval = 0, note: String? = nil
        ) {
            self.stage = stage
            self.outcome = outcome
            self.inputCount = inputCount
            self.outputCount = outputCount
            self.duration = duration
            self.note = note
        }

        public init(
            stage: RetrievalStage, ran: Bool, inputCount: Int, outputCount: Int,
            duration: TimeInterval = 0, note: String? = nil
        ) {
            self.init(
                stage: stage, outcome: ran ? .ran : .skipped,
                inputCount: inputCount, outputCount: outputCount,
                duration: duration, note: note
            )
        }

        public var line: String {
            guard ran else {
                return String(localized: "\(stage.title): \(outcome.title)\(note.map { " — \($0)" } ?? "")")
            }
            let time = String(format: "%.0f мс", duration * 1000)
            let counts = inputCount == outputCount
                ? String(localized: "\(outputCount)")
                : String(localized: "\(inputCount) → \(outputCount)")
            return String(localized: "\(stage.title): \(counts), \(time)\(note.map { " — \($0)" } ?? "")")
        }
    }

    public var profileName: String = ""
    /// One line about the run as a whole, set by whoever started it.
    ///
    /// The pipeline cannot know why it was given the profile it was given —
    /// «умный поиск выключен» is a fact about the app's switch, not about any
    /// stage — and a panel where every stage says «в профиле не включено» would
    /// name the wrong cause.
    public var note: String?
    /// Ни одна необязательная стадия не изменила выдачу.
    ///
    /// Отдельным полем, а не текстом в `note`: `note` пишет приложение — им
    /// оно объясняет **свой** переключатель, — а это факт о прогоне, и знать
    /// его должен всякий, кто смотрит на диагностику.
    public var unchangedByProfile = false
    public var stages: [StageReport] = []
    /// Time spent turning the query into a vector, or `nil` when no vector was
    /// needed at all («только текстовый поиск»).
    ///
    /// Kept apart from stage 1: it is usually most of the wait, and hiding it
    /// inside «генерация кандидатов» would send someone optimising the wrong
    /// thing. Nil rather than zero, because zero is a real and interesting
    /// answer — it is what a cache hit looks like.
    public var embeddingDuration: TimeInterval?
    public var totalDuration: TimeInterval = 0

    public var summary: String {
        String(localized: "профиль «\(profileName)», всего \(String(format: "%.0f", totalDuration * 1000)) мс")
    }

    /// Shown apart from the stages for the same reason it is timed apart: on a
    /// slow query it is usually most of the wait, and a panel that hid it would
    /// send somebody tuning the pipeline instead of the model.
    public var embeddingLine: String? {
        guard let embeddingDuration else { return nil }
        return String(localized: "Вектор запроса: \(String(format: "%.0f", embeddingDuration * 1000)) мс")
    }

    /// The whole panel as plain text.
    ///
    /// The panel holds the last query only; a complaint about search travels by
    /// mail. This is what «скопировать» puts on the clipboard.
    public var plainText: String {
        var lines = [String(localized: "Как получен этот результат — \(summary)")]
        if let note { lines.append(note) }
        if let embeddingLine { lines.append(embeddingLine) }
        lines += stages.sorted { $0.stage.order < $1.stage.order }.map(\.line)
        return lines.joined(separator: "\n")
    }

    /// The stage that took longest, so the panel can point at it without the
    /// reader comparing eight numbers by eye. Nothing is marked when the whole
    /// query was too fast for the difference to mean anything.
    public var slowestStage: RetrievalStage? {
        guard totalDuration >= 0.05 else { return nil }
        let ranStages = stages.filter(\.ran)
        guard let slowest = ranStages.max(by: { $0.duration < $1.duration }),
              slowest.duration > totalDuration * 0.25 else { return nil }
        return slowest.stage
    }
}

public struct RetrievalOutcome: Sendable {
    public var hits: [RetrievalHit]
    public var diagnostics: RetrievalDiagnostics

    public init(hits: [RetrievalHit], diagnostics: RetrievalDiagnostics) {
        self.hits = hits
        self.diagnostics = diagnostics
    }
}

/// The one path every search in the app takes.
///
/// Search screen, the MCP `search` tool, the evaluation stand, the test bench —
/// all of them come through here. The rule is structural rather than tidy: the
/// moment a second implementation exists, the settings a user tuned apply in
/// one place and not the other, and nobody can say which answer they are
/// looking at.
///
/// The vector is not computed here. Embedding needs the model, the binding
/// check and the task queue, all of which belong to the app; the pipeline takes
/// a closure and stays free of them — which is also what lets a test run every
/// stage without LM Studio.
public actor RetrievalPipeline {
    public typealias Embedder = @Sendable (String) async throws -> [Double]
    /// Prompt, model and the schema the answer must fit — the app supplies the
    /// LM Studio call, the queue and the timeout.
    public typealias ChatCompleter = @Sendable (String, String, ChatJSONSchema) async throws -> String
    /// Промпт и модель — без схемы и без шаблона чата. Нужен
    /// специализированным переранжировщикам: их разметку промпта шаблон чата
    /// ломает, а схемы они не понимают вовсе.
    public typealias PlainCompleter = @Sendable (String, String) async throws -> String

    private let database: any RetrievalDatabase
    private let shapes: CollectionShapeCache
    private let embed: Embedder
    private let complete: ChatCompleter?
    private let completePlain: PlainCompleter?
    /// Контекст, с которым **загружена** модель переранжирования, — не потолок
    /// из её карточки: потолок недостижим без перезагрузки модели.
    /// `nil` — LM Studio не сказала; тогда бюджет не считается.
    private let rerankContextTokens: Int?
    /// Измеренное «символов на токен» модели переранжирования.
    /// `nil` — не измерялось, тогда берётся пессимистичная оценка.
    private let rerankCharactersPerToken: Double?
    private let log: LogHandler

    public init(
        database: any RetrievalDatabase,
        shapes: CollectionShapeCache = CollectionShapeCache(),
        embed: @escaping Embedder,
        complete: ChatCompleter? = nil,
        completePlain: PlainCompleter? = nil,
        rerankContextTokens: Int? = nil,
        rerankCharactersPerToken: Double? = nil,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.database = database
        self.shapes = shapes
        self.embed = embed
        self.complete = complete
        self.completePlain = completePlain
        self.rerankContextTokens = rerankContextTokens
        self.rerankCharactersPerToken = rerankCharactersPerToken
        self.log = log
    }

    public func run(_ request: RetrievalRequest, profile: SearchProfile) async throws -> RetrievalOutcome {
        let started = Date()
        var diagnostics = RetrievalDiagnostics()
        diagnostics.profileName = profile.name

        let nResults = max(1, min(request.nResults, 100))

        // What the profile asks for, narrowed by what the collection can
        // actually provide. A one-level collection makes the hierarchy stages
        // impossible, and they must then cost nothing at all — not even a
        // larger candidate pool.
        let shape = await shapes.shape(
            of: request.collectionID, collectionName: request.collectionName, database: database
        )
        var stages = profile.requestedStages
        if !shape.isHierarchical { stages.subtract([.collapse, .promote]) }
        let pool = profile.poolSize(nResults: nResults, stages: stages)
        var skipped: [RetrievalStage: String] = [:]
        for stage in profile.requestedStages.subtracting(stages) {
            skipped[stage] = String(localized: "коллекция нарезана одним уровнем")
        }

        // MARK: Stage 1 — candidates
        //
        // One list or two. Vector search needs the query embedded; text
        // search does not, and «только текстовый поиск» must not pay for a
        // vector it will never use.
        let wantsVector = profile.vectorSearchEnabled || !profile.textSearchEnabled
        let (filter, levelNote) = candidateFilter(request: request, profile: profile, shape: shape)

        // Embedding is timed apart from the stage and happens before its clock
        // starts: it is usually most of the wait, and folding it into «генерация
        // кандидатов» would send someone optimising the wrong thing.
        var vector: [Double] = []
        if wantsVector {
            let embeddingStarted = Date()
            vector = try await embed(profile.embeddedQuery(request.text))
            diagnostics.embeddingDuration = Date().timeIntervalSince(embeddingStarted)
        }

        let candidatesStarted = Date()
        var vectorHits: [RetrievalHit] = []
        if wantsVector {
            vectorHits = try await database.query(
                collectionID: request.collectionID,
                embedding: vector,
                nResults: pool,
                filter: filter,
                includeEmbeddings: stages.contains(.diversity)
            ).enumerated().map { RetrievalHit($1, position: $0 + 1) }
        }

        var textHits: [RetrievalHit] = []
        var textNote: String?
        if profile.textSearchEnabled {
            let found = try await textCandidates(
                request: request, profile: profile, filter: filter, limit: pool
            )
            textHits = found.hits
            textNote = found.note
        }

        // Длина кандидата — работа **внутри** стадии 1, а не новая стадия
        // в середине конвейера: порядок стадий из E0.1 неизменен,
        // а отсекать и штрафовать надо там, где кандидаты ещё есть.
        // Каждому списку — свой проход: у текстового поиска своя выдача,
        // и слияние ниже считает ранги уже по исправленному порядку.
        var lengthNotes: [String] = []
        // Работа по длине — не стадия конвейера, поэтому «профиль ничего
        // не изменил» не увидел бы её сам: считаем отдельно.
        var lengthChangedSomething = false
        // Отсечка — здесь, до слияния: слишком короткий кандидат не должен
        // попасть в списки вовсе. А **штраф** считается один раз и после
        // слияния: он домножает ту оценку, по которой список и
        // упорядочен, а до слияния такой оценки ещё нет.
        if profile.minimumCharacters > 0 {
            let vectorOutcome = LengthPreference.applied(
                to: vectorHits, minimumCharacters: profile.minimumCharacters, penalty: false,
                target: profile.lengthTarget, power: profile.lengthPenaltyPower, metric: request.metric
            )
            vectorHits = vectorOutcome.hits
            if let note = vectorOutcome.note { lengthNotes.append(note) }
            lengthChangedSomething = vectorOutcome.dropped > 0

            if !textHits.isEmpty {
                let textOutcome = LengthPreference.applied(
                    to: textHits, minimumCharacters: profile.minimumCharacters, penalty: false,
                    target: profile.lengthTarget, power: profile.lengthPenaltyPower, metric: request.metric
                )
                textHits = textOutcome.hits
                if textOutcome.dropped > 0 {
                    lengthNotes.append(String(localized: "в текстовом списке отброшено \(textOutcome.dropped.plainDigits)"))
                    lengthChangedSomething = true
                }
            }
        }

        var hits = vectorHits
        var candidateNote = pool == nResults
            ? String(localized: "запрошено \(pool) — пул не нужен, дальше ничего не отсеивает")
            : String(localized: "запрошено \(pool)")
        if !wantsVector { candidateNote = String(localized: "векторный поиск выключен") }
        if let levelNote { candidateNote += ", \(levelNote)" }
        // Приставка к запросу — в отчёт: иначе две выдачи с разным
        // вектором одного и того же запроса выглядели бы необъяснимо.
        if wantsVector, !profile.queryPrefix.isEmpty {
            // Многоточие — только там, где вправду обрезали: приставка nomic
            // короче сорока знаков, и «search_query:…» отправило бы читателя
            // искать продолжение, которого нет.
            let shown = profile.queryPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let cut = shown.count > 40 ? shown.prefix(40) + "…" : shown[...]
            candidateNote += ", " + String(localized: "приставка к запросу: \(String(cut))")
        }
        if let textNote { candidateNote += ", \(textNote)" }
        for note in lengthNotes { candidateNote += ", \(note)" }
        diagnostics.stages.append(.init(
            stage: .candidates, ran: true, inputCount: 0,
            outputCount: vectorHits.count + textHits.count,
            duration: Date().timeIntervalSince(candidatesStarted), note: candidateNote
        ))

        // MARK: Stage 2 — fusion
        if !vectorHits.isEmpty && !textHits.isEmpty {
            let stageStarted = Date()
            let fused = Self.fusing(
                vector: vectorHits, text: textHits,
                vectorWeight: profile.vectorWeight, textWeight: profile.textWeight,
                k: profile.fusionK
            )
            hits = fused.hits
            diagnostics.stages.append(.init(
                stage: .fusion, ran: true,
                inputCount: vectorHits.count + textHits.count, outputCount: hits.count,
                duration: Date().timeIntervalSince(stageStarted), note: fused.note
            ))
        } else {
            // One source and nothing to merge — including the case where the
            // other source simply found nothing, which is worth saying.
            if textHits.isEmpty && profile.textSearchEnabled && !vectorHits.isEmpty {
                hits = vectorHits
                diagnostics.stages.append(.init(
                    stage: .fusion, ran: false, inputCount: hits.count, outputCount: hits.count,
                    note: String(localized: "текстовый поиск ничего не нашёл — сливать не с чем")
                ))
            } else if vectorHits.isEmpty && !textHits.isEmpty {
                hits = textHits
                diagnostics.stages.append(.init(
                    stage: .fusion, ran: false, inputCount: hits.count, outputCount: hits.count,
                    note: String(localized: "только текстовый поиск")
                ))
            } else {
                diagnostics.stages.append(.init(
                    stage: .fusion, ran: false, inputCount: hits.count, outputCount: hits.count,
                    note: String(localized: "второй источник кандидатов не включён")
                ))
            }
        }

        // Штраф за длину — один раз, поверх оценки слияния.
        //
        // Считать его внутри каждого списка бесполезно: RRF складывает ранги
        // заново, и короткий чанк, найденный обоими источниками, выходит
        // вперёд мимо штрафа — замер на живой базе, запрос «сервер»: чанк
        // в 54 знака стоял первым, вторым, третьим и четвёртым (дубли),
        // получив по вкладу от каждого источника.
        if profile.lengthPenaltyEnabled {
            let outcome = LengthPreference.applied(
                to: hits, minimumCharacters: 0, penalty: true,
                target: profile.lengthTarget, power: profile.lengthPenaltyPower,
                metric: request.metric
            )
            hits = outcome.hits
            if outcome.moved > 0 { lengthChangedSomething = true }
            if let note = outcome.note, let last = diagnostics.stages.indices.last {
                let report = diagnostics.stages[last]
                diagnostics.stages[last] = .init(
                    stage: report.stage, outcome: report.outcome,
                    inputCount: report.inputCount, outputCount: report.outputCount,
                    duration: report.duration,
                    note: [report.note, note].compactMap { $0 }.joined(separator: ", ")
                )
            }
        }

        // MARK: Stage 3 — collapse by parent
        if stages.contains(.collapse) {
            let stageStarted = Date()
            let before = hits.count
            hits = Self.collapsingByParent(hits)
            diagnostics.stages.append(.init(
                stage: .collapse, ran: true, inputCount: before, outputCount: hits.count,
                duration: Date().timeIntervalSince(stageStarted),
                note: before == hits.count
                    ? String(localized: "у кандидатов нет общих родителей")
                    : String(localized: "свёрнуто \(RussianCount.phrase(before - hits.count, "дочерний чанк", "дочерних чанка", "дочерних чанков")) в \(RussianCount.phrase(hits.filter { $0.collapsed > 0 }.count, "раздел", "раздела", "разделов"))")
            ))
        } else {
            diagnostics.stages.append(off(.collapse, count: hits.count, skipped: skipped))
        }

        // MARK: Stage 4 — diversity (not yet)
        // MARK: Stage 4 — diversity
        if stages.contains(.diversity) {
            let stageStarted = Date()
            let before = hits.count
            let diversified = Self.diversifying(
                hits, count: nResults, lambda: profile.diversityLambda, metric: request.metric
            )
            hits = diversified.hits
            diagnostics.stages.append(.init(
                stage: .diversity, ran: true, inputCount: before, outputCount: hits.count,
                duration: Date().timeIntervalSince(stageStarted), note: diversified.note
            ))
        } else {
            diagnostics.stages.append(off(.diversity, count: hits.count, skipped: skipped))
        }

        // MARK: Stage 5 — promotion to the parent
        if stages.contains(.promote) {
            let stageStarted = Date()
            let before = hits.count
            let promoted = try await promoting(hits, mode: profile.promotion, collectionID: request.collectionID)
            hits = promoted.hits
            diagnostics.stages.append(.init(
                stage: .promote, ran: true, inputCount: before, outputCount: hits.count,
                duration: Date().timeIntervalSince(stageStarted),
                note: promoted.note
            ))
        } else {
            diagnostics.stages.append(off(.promote, count: hits.count, skipped: skipped))
        }

        // MARK: Stages 6–7 — context and reranking (not yet)
        // MARK: Stage 6 — neighbouring chunks
        //
        // After promotion, deliberately: on a hierarchical collection the result
        // is by then the parent, whose neighbours by index are its own children.
        // That is why the window defaults to zero there.
        let window = profile.resolvedContextWindow
        if window > 0 {
            let stageStarted = Date()
            let expanded = try await expandingContext(
                hits, window: window, collectionID: request.collectionID
            )
            hits = expanded.hits
            var note = expanded.note
            // Asked for, so done — with the consequence named. On a promoted
            // result the neighbours by index are the section's own children.
            if shape.isHierarchical, profile.promotion != .child {
                note = [note, String(localized: "внимание: соседи родительского чанка — его собственные дети")]
                    .compactMap { $0 }.joined(separator: "; ")
            }
            diagnostics.stages.append(.init(
                stage: .context, ran: true, inputCount: hits.count, outputCount: hits.count,
                duration: Date().timeIntervalSince(stageStarted), note: note
            ))
        } else {
            diagnostics.stages.append(.init(
                stage: .context, ran: false, inputCount: hits.count, outputCount: hits.count,
                note: String(localized: "в профиле не включено")
            ))
        }
        // MARK: Stage 7 — reranking by a chat model
        // Готовность стадии зависит от режима: чат-схеме нужна чат-модель,
        // переранжировщику — прямой вызов. Проверять только чат значило бы
        // объявлять «модель не передана» там, где она и не нужна.
        let rerankReady = profile.rerankMode == .crossEncoder
            ? completePlain != nil
            : complete != nil
        if stages.contains(.rerank), rerankReady {
            let stageStarted = Date()
            let before = hits.count
            do {
                let result = try await reranking(hits, profile: profile, query: request.text)
                hits = result.hits
                diagnostics.stages.append(.init(
                    stage: .rerank, ran: true, inputCount: before, outputCount: hits.count,
                    duration: Date().timeIntervalSince(stageStarted),
                    note: result.note
                ))
            } catch {
                // A model that refused, timed out or answered nonsense must not
                // take the search down with it: the list stays as the previous
                // stages left it, and the reason is on the record.
                log(.warning, "Поиск", "Переранжирование не выполнено: \(error.localizedDescription)")
                diagnostics.stages.append(.init(
                    stage: .rerank, outcome: .failed, inputCount: before, outputCount: before,
                    duration: Date().timeIntervalSince(stageStarted),
                    note: error.localizedDescription
                ))
            }
        } else if stages.contains(.rerank) {
            diagnostics.stages.append(.init(
                stage: .rerank, outcome: .failed, inputCount: hits.count, outputCount: hits.count,
                note: profile.rerankMode == .crossEncoder
                    ? String(localized: "прямой вызов модели этому конвейеру не передан")
                    : String(localized: "чат-модель этому конвейеру не передана")
            ))
        } else {
            diagnostics.stages.append(.init(
                stage: .rerank, ran: false, inputCount: hits.count, outputCount: hits.count,
                note: profile.rerankEnabled && profile.rerankModel.isEmpty
                    ? String(localized: "включено, но модель не выбрана")
                    : String(localized: "в профиле не включено")
            ))
        }

        // MARK: Stage 8 — ручные пометки человека
        //
        // Последними, но до обрезки: закреплённое человеком обязано попасть
        // в выдачу, а не быть срезанным вместе с хвостом. Внутри своей группы
        // порядок сохраняется — пометка говорит «выше» и «ниже», а не «вместо».
        if stages.contains(.marks) {
            let marksStarted = Date()
            let before = hits.count
            // Закреплённое сначала **добирается**, и только потом
            // список двигается. Стадия работала с тем, что вернул вектор,
            // а закрепляют как раз то, что вектор находить не хочет: при
            // n_results 5 документ, стоящий восьмым по близости, в кандидаты
            // не попадал вовсе — и «Закрепить» не делало ровно ничего.
            // Отдельным запросом, а не расширением пула: помеченных
            // документов единицы, а пул платили бы все поиски подряд, и
            // «выключенный конвейер даёт то же, что этап 2» перестало бы
            // быть правдой буквально.
            //
            // Спрашиваем базу только там, где закреплённые вообще есть:
            // ответ на этот вопрос кеширован на коллекцию, иначе каждый поиск
            // платил бы обходом метаданных ради «нет».
            var pinnedNote: String?
            let worthAsking = await shapes.hasPinnedDocuments(
                collectionID: request.collectionID, database: database
            )
            if worthAsking, let added = try? await pinnedBeyond(
                hits, collectionID: request.collectionID, filter: request.filter
            ), !added.isEmpty {
                hits += added
                pinnedNote = String(localized: "добрано закреплённых: \(added.count.plainDigits)")
            }
            let marked = Self.applyingMarks(hits)
            hits = marked.hits
            diagnostics.stages.append(.init(
                stage: .marks, ran: true, inputCount: before, outputCount: hits.count,
                duration: Date().timeIntervalSince(marksStarted),
                note: [pinnedNote, marked.note].compactMap { $0 }.joined(separator: ", ")
            ))
        } else {
            diagnostics.stages.append(.init(
                stage: .marks, ran: false, inputCount: hits.count, outputCount: hits.count,
                duration: 0, note: String(localized: "в профиле не включено")
            ))
        }

        // MARK: Stage 9 — truncate
        let truncateStarted = Date()
        let before = hits.count
        if hits.count > nResults { hits = Array(hits.prefix(nResults)) }
        diagnostics.stages.append(.init(
            stage: .truncate, ran: true, inputCount: before, outputCount: hits.count,
            duration: Date().timeIntervalSince(truncateStarted),
            note: before > hits.count
                ? String(localized: "отброшено \(before - hits.count) сверх n_results")
                : String(localized: "отбрасывать нечего: кандидатов не больше, чем запрошено")
        ))

        // Сказать вслух, когда «умный поиск» не отличается от обычного.
        //
        // Заводской профиль включает три стадии: свёртку по родителю, подъём
        // к разделу и пометки человека. Первые две коллекции, нарезанной одним
        // уровнем, недоступны вовсе, а третья без единой пометки ничего
        // не двигает — и запрос уходит в базу тем же вектором, с тем же
        // n_results, и возвращает ровно тот же список, что и с выключенным
        // переключателем. Человек, который специально включил галочку и не
        // увидел разницы, вправе считать её сломанной; правило 2 требует
        // назвать причину, а не оставлять его гадать.
        diagnostics.unchangedByProfile = Self.profileChangedNothing(
            stages: diagnostics.stages, requested: profile.requestedStages,
            lengthChangedSomething: lengthChangedSomething
        )
        diagnostics.totalDuration = Date().timeIntervalSince(started)
        log(.debug, "Поиск",
            "Запрос к «\(request.collectionName)»: \(RussianCount.phrase(hits.count, "результат", "результата", "результатов")), \(diagnostics.summary)")
        // The same thing the panel of E0.4 shows, in a form a user can send when
        // they say «поиск стал хуже» — the panel holds the last query only. One
        // line per stage, at debug level, so it costs nothing until somebody
        // looks.
        for report in diagnostics.stages where report.ran || report.note != nil {
            log(.debug, "Поиск", "  \(report.line)")
        }
        return RetrievalOutcome(hits: hits, diagnostics: diagnostics)
    }

    /// Закреплённые документы коллекции, которых нет в выдаче.
    ///
    /// Спрашивается только у стадии пометок и только по самой пометке:
    /// `_cdbm_mark == pinned`. Закреплённых в коллекции единицы — человек
    /// ставит эту пометку руками, — поэтому запрос дешёвый и предел ему
    /// поставлен небольшой: закрепить пол-коллекции и ждать, что всё это
    /// приедет в каждую выдачу, значит не искать вовсе.
    ///
    /// Понижённые и устаревшие не добираются: они говорят «ниже», а не
    /// «покажи», и притаскивать их в выдачу ради того, чтобы опустить
    /// в самый низ, — работа впустую.
    ///
    /// Фильтр человека уважается: закреплённое, не подходящее под условия
    /// запроса, не показывается — «только за прошлый год» остаётся правдой.
    private func pinnedBeyond(
        _ hits: [RetrievalHit], collectionID: String, filter: DocumentFilter?
    ) async throws -> [RetrievalHit] {
        var pinnedFilter = filter ?? DocumentFilter()
        // Фильтр, написанный руками в JSON, не трогается: дописать в него
        // условие — значит переписать чужой запрос (то же правило, что
        // и у выбора уровня иерархии).
        guard !pinnedFilter.usesRawJSON else { return [] }
        pinnedFilter.root = .group(.and, pinnedFilter.root.children + [
            .leaf(MetadataCondition(
                field: DocumentMarks.markKey, op: .equals, value: DocumentMark.pinned.rawValue
            )),
        ])
        let known = Set(hits.map(\.id))
        let found = try await database.documents(
            collectionID: collectionID, matching: pinnedFilter, limit: Self.pinnedLimit
        )
        return found
            .filter { !known.contains($0.id) }
            // Ни расстояния, ни места в списке источника: этот документ нашёл
            // не поиск, а пометка человека. Врать про расстояние, которого
            // никто не мерил, нельзя — карточка результата покажет пометку,
            // и по ней видно, почему он здесь.
            .map {
                RetrievalHit(
                    id: $0.id, document: $0.document, metadata: $0.metadata,
                    distance: nil, sources: [], placements: []
                )
            }
    }

    /// Сколько закреплённых документов доберётся в выдачу.
    static let pinnedLimit = 20

    /// Ни одна необязательная стадия не тронула выдачу.
    ///
    /// Считается по отчётам стадий, а не по настройкам: стадия могла быть
    /// включена в профиле и всё равно не сработать — потому что коллекция
    /// плоская, потому что в выдаче нет ни одной пометки, потому что модель
    /// переранжировщика не выбрана. Именно результат, а не намерение, отвечает
    /// на вопрос «почему галочка ничего не изменила».
    ///
    /// Пометки — особый случай: стадия отработала, но при отсутствии
    /// помеченных документов она возвращает список как есть, и это видно
    /// по её собственной заметке.
    static func profileChangedNothing(
        stages: [RetrievalDiagnostics.StageReport], requested: Set<RetrievalStage>,
        lengthChangedSomething: Bool = false
    ) -> Bool {
        // Штраф и отсечка по длине живут внутри стадии 1 и своей строки
        // в отчёте стадий не имеют — а выдачу меняют.
        if lengthChangedSomething { return false }
        guard !requested.isEmpty else { return true }
        for report in stages where report.stage.isOptional {
            guard report.ran else { continue }
            if report.stage == .marks, report.outputCount == report.inputCount,
               report.note == String(localized: "помеченных документов в выдаче нет") {
                continue
            }
            return false
        }
        return true
    }

    // MARK: - Stage 8: ручные пометки

    /// Двигает список по пометкам человека, **сохраняя порядок внутри групп**.
    ///
    /// Устойчивая сортировка, а не пересчёт очков: очко пометки пришлось бы
    /// выражать в тех же единицах, что и релевантность, а они не сравнимы —
    /// «насколько закреплённое важнее похожего» не имеет ответа. Порядок
    /// групп: закреплённые, обычные, понижённые, устаревшие; внутри группы
    /// всё остаётся так, как оставил конвейер.
    static func applyingMarks(_ hits: [RetrievalHit]) -> (hits: [RetrievalHit], note: String) {
        var groups: [Int: [RetrievalHit]] = [:]
        var counts: [DocumentMark: Int] = [:]
        for hit in hits {
            let mark = DocumentMarks(metadata: hit.metadata).mark
            if let mark { counts[mark, default: 0] += 1 }
            groups[mark?.rankGroup ?? 1, default: []].append(hit)
        }
        guard !counts.isEmpty else {
            return (hits, String(localized: "помеченных документов в выдаче нет"))
        }
        let ordered = groups.keys.sorted().flatMap { groups[$0] ?? [] }
        var parts: [String] = []
        if let pinned = counts[.pinned] { parts.append(String(localized: "закреплённых \(pinned.plainDigits)")) }
        if let demoted = counts[.demoted] { parts.append(String(localized: "понижённых \(demoted.plainDigits)")) }
        if let stale = counts[.stale] { parts.append(String(localized: "устаревших \(stale.plainDigits)")) }
        return (ordered, parts.joined(separator: ", "))
    }

    // MARK: - Stage 1: which level to search

    /// The user's filter, narrowed to one level of the hierarchy when that
    /// applies.
    ///
    /// Two things it deliberately does not do. It adds nothing to a one-level
    /// collection: documents written by another client may carry no
    /// `chunk_level` at all, and a condition on a field they lack would drop
    /// them without a word. And it leaves a filter written as raw JSON exactly
    /// as written — an explicit query is the user's, and quietly appending a
    /// condition to it would break rule 2 of Приложение 5.
    private func candidateFilter(
        request: RetrievalRequest, profile: SearchProfile, shape: CollectionShape
    ) -> (DocumentFilter?, String?) {
        guard shape.isHierarchical, let condition = profile.searchLevel.condition else {
            return (request.filter, nil)
        }
        var filter = request.filter ?? DocumentFilter()
        guard !filter.usesRawJSON else {
            return (request.filter, String(localized: "уровень не ограничен: фильтр задан вручную в JSON"))
        }
        filter.root = .group(.and, filter.root.children + [.leaf(condition)])
        return (filter, String(localized: "поиск по \(profile.searchLevel.title)"))
    }

    // MARK: - Stage 3: one result per parent

    /// Children of one parent become one result, keeping the best distance.
    ///
    /// Order is preserved: the collection returned candidates nearest-first,
    /// and a fold must not reshuffle them. A candidate with no parent — a chunk
    /// of a flat file in a mixed collection, or a parent that matched directly
    /// — passes through untouched rather than being grouped with the others.
    static func collapsingByParent(_ hits: [RetrievalHit]) -> [RetrievalHit] {
        var result: [RetrievalHit] = []
        var positionOfParent: [String: Int] = [:]
        for hit in hits {
            guard let parent = hit.parentChunkID else {
                result.append(hit)
                continue
            }
            if let index = positionOfParent[parent] {
                result[index].collapsed += 1
                // The best of the folded distances, because that is what the
                // section actually scored — not the one that happened to be
                // first.
                if let existing = result[index].distance, let incoming = hit.distance, incoming < existing {
                    result[index].distance = incoming
                }
                continue
            }
            positionOfParent[parent] = result.count
            result.append(hit)
        }
        return result
    }

    // MARK: - Stage 5: the parent instead of, or beside, the child

    private func promoting(
        _ hits: [RetrievalHit], mode: ParentPromotion, collectionID: String
    ) async throws -> (hits: [RetrievalHit], note: String?) {
        guard mode != .child else { return (hits, nil) }
        let parentIDs = Array(Set(hits.compactMap(\.parentChunkID)))
        guard !parentIDs.isEmpty else {
            return (hits, String(localized: "среди результатов нет дочерних чанков"))
        }

        // One request for every parent of the page, not one per result.
        let records = try await database.documents(collectionID: collectionID, ids: parentIDs)
        let parents = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !parents.isEmpty else {
            // The link points at a document that is not there — a re-index that
            // rewrote parents but not children, most likely. Saying so beats
            // returning children as if promotion had been asked for and done.
            return (hits, String(localized: "родительские чанки не найдены в коллекции — возвращены дочерние"))
        }

        var missing = 0
        let result = hits.map { hit -> RetrievalHit in
            guard let parentID = hit.parentChunkID else { return hit }
            guard let parent = parents[parentID] else {
                missing += 1
                return hit
            }
            switch mode {
            case .child:
                return hit
            case .parent:
                // The result becomes the parent — id included. Keeping the
                // child's id beside the parent's text would make «открыть этот
                // документ» open something else than the card shows.
                //
                // The distance stays the child's: it is what was matched, and
                // ranking by the parent's text would rank by context.
                return RetrievalHit(
                    id: parent.id, document: parent.document, metadata: parent.metadata,
                    distance: hit.distance, sources: hit.sources, placements: hit.placements,
                    role: hit.role,
                    collapsed: hit.collapsed, matchedChunkID: hit.id, context: hit.context
                )
            case .both:
                var promoted = hit
                promoted.context.append(RetrievalHit(
                    id: parent.id, document: parent.document, metadata: parent.metadata,
                    distance: nil, sources: hit.sources, role: .context, contextKind: .parent
                ))
                return promoted
            }
        }
        let note = mode == .both
            ? String(localized: "родитель добавлен как контекст к \(parentIDs.count - missing) результатам")
            : String(localized: "поднято к родителю: \(parentIDs.count - missing)")
        return (result, missing > 0 ? note + String(localized: ", не найдено родителей: \(missing)") : note)
    }

    // MARK: - Stage 1: the text source

    /// Candidates found by the text itself, ranked by the app.
    ///
    /// The rank is **not** the order the server returned. `get` guarantees no
    /// order at all, so «позиция в текстовом списке» would change between
    /// identical runs — and RRF is built out of positions. The formula lives in
    /// `TextRelevance` and is covered by a test.
    /// Готовое условие обратно в текст — им задаётся `where_document`,
    /// когда форма сложнее одного уровня логики и редактор её не выражает.
    static func json(of object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func textCandidates(
        request: RetrievalRequest, profile: SearchProfile, filter: DocumentFilter?, limit: Int
    ) async throws -> (hits: [RetrievalHit], note: String?) {
        let terms = TextRelevance.terms(in: request.text, splitIntoWords: profile.splitQueryIntoWords)
        guard !terms.isEmpty else { return ([], String(localized: "текстовый поиск: пустой запрос")) }

        // `$contains` у ChromaDB различает регистр, а ранжирование здесь — нет.
        // Без вариантов написания стадия честно спрашивала «astra» у текста со
        // словом «Astra» и не находила ничего.
        let variants = TextRelevance.caseVariants(of: terms)
        var textFilter = filter ?? DocumentFilter()
        // Условие по тексту, заданное вызывающим («документ обязан содержать
        // это слово»), — ограничение, а не подсказка. Дописать варианты запроса
        // в тот же список значило бы соединить их с ним через `$or` и вернуть
        // документы, которые чужого условия не выполняют вовсе.
        let existing = textFilter.whereDocumentClause()
        let ownClause: [String: Any] = variants.count > 1
            ? [FilterLogic.or.rawValue: variants.map { [DocumentTextOperator.contains.rawValue: $0] }]
            : [DocumentTextOperator.contains.rawValue: variants.first ?? ""]

        if let existing {
            textFilter.textConditions = []
            textFilter.rawWhereDocumentJSON = Self.json(
                of: [FilterLogic.and.rawValue: [existing, ownClause]]
            ) ?? ""
        } else {
            textFilter.textConditions += variants.map { DocumentTextCondition(op: .contains, text: $0) }
            // Several words are looked for with `$or`: a document containing every
            // word of a phrase is rare, and `$and` would find nothing at all.
            textFilter.textLogic = variants.count > 1 ? .or : .and
        }

        let records = try await database.documents(
            collectionID: request.collectionID, matching: textFilter, limit: limit
        )
        let ranked = TextRelevance.ranked(records, terms: terms)
        // Текстовый кандидат несёт свою оценку дальше по конвейеру.
        //
        // Расстояния у него нет и быть не может: `$contains` отвечает
        // «содержит», а не «насколько похоже». Зато есть вес по редкости
        // слов, которым эта половина и упорядочена, — приведённый к 0…1
        // по лучшему в списке. Без него штраф за длину до текстовой
        // половины не доходил, и она возвращала в верхушку ровно тот
        // короткий мусор, который он убирал: на живом замере коротких
        // чанков в первой пятёрке было 4.2 из 5 — столько же, сколько
        // без всякого штрафа.
        let best = ranked.first?.score ?? 1
        let hits = ranked.enumerated().map { position, entry in
            var hit = RetrievalHit(
                id: entry.record.id, document: entry.record.document,
                metadata: entry.record.metadata, distance: nil, sources: [.text],
                placements: [SourcePlacement(source: .text, position: position + 1)]
            )
            hit.relevance = best > 0 ? entry.score / best : 0
            return hit
        }
        var note = String(localized: "текстовый поиск: найдено \(records.count), с ненулевым весом \(hits.count), написаний запрошено \(variants.count)")
        // Фраза ищется целиком — и «astra linux орел» не находится там, где эти
        // слова стоят порознь. Сказать об этом здесь дешевле, чем оставить
        // пользователя с «ничего не нашёл» и выключателем, о котором он не
        // вспомнит.
        if records.isEmpty, !profile.splitQueryIntoWords, terms.first?.contains(" ") == true {
            note += String(localized: ". Фраза искалась целиком — включите «разбивать запрос на слова», если нужны отдельные слова")
        }
        return (hits, note)
    }

    // MARK: - Stage 2: two lists become one

    /// Reciprocal Rank Fusion.
    ///
    /// Ranks rather than scores, because a cosine distance and a position in a
    /// text listing cannot be added. A document present in both lists gains from
    /// both and rises above one that only one source found — which is the whole
    /// reason for having two.
    static func fusing(
        vector: [RetrievalHit], text: [RetrievalHit],
        vectorWeight: Double, textWeight: Double, k: Double
    ) -> (hits: [RetrievalHit], note: String?) {
        let fused = ReciprocalRankFusion.fuse(
            [
                .init(source: .vector, ids: vector.map(\.id), weight: vectorWeight),
                .init(source: .text, ids: text.map(\.id), weight: textWeight),
            ],
            k: k
        )
        // The vector list is preferred as the carrier of a document's fields: it
        // brings the distance, and — when MMR is next — the embedding.
        var byID: [String: RetrievalHit] = [:]
        for hit in text { byID[hit.id] = hit }
        for hit in vector { byID[hit.id] = hit }

        // Лучшая оценка слияния — единица шкалы.
        //
        // Сырое значение RRF мало по устройству: у первого места это
        // 1/(k+1) ≈ 0.016. Отдать его дальше как «релевантность» нельзя —
        // стадия разнообразия сравнивает её с косинусной похожестью
        // кандидатов в 0…1, и слагаемое релевантности оказывается в тридцать
        // раз легче слагаемого повторности: MMR перестаёт смотреть, о чём
        // вообще документ. Приводим к 0…1, как это уже сделано у текстовой
        // половины.
        let bestFused = fused.first?.score ?? 1
        let hits = fused.compactMap { entry -> RetrievalHit? in
            guard var hit = byID[entry.id] else { return nil }
            hit.sources = entry.sources
            // Оценка слияния идёт дальше по конвейеру: у
            // документа, найденного обоими источниками, она выше, и штраф
            // за длину обязан домножать именно её. Иначе он считается внутри
            // каждого списка по отдельности, а RRF потом складывает ранги
            // заново — и короткий чанк, попавший в оба списка, выходит вперёд
            // мимо всякого штрафа.
            hit.relevance = bestFused > 0 ? entry.score / bestFused : 0
            // Where each source had it before the merge — the one thing the
            // fused order itself no longer shows.
            hit.placements = entry.placements.map {
                SourcePlacement(source: $0.source, position: $0.position)
            }
            return hit
        }
        let inBoth = fused.filter { $0.placements.count > 1 }.count
        return (
            hits,
            String(localized: "векторных \(vector.count), текстовых \(text.count), в обоих списках \(inBoth), rrf_k \(Int(k))")
        )
    }

    // MARK: - Stage 4: results that do not repeat each other

    /// Reorders the pool by MMR and keeps the best `count`.
    ///
    /// **Relevance comes from the collection, not from the vectors.** For a
    /// cosine collection the distance converts to a bounded similarity and is
    /// used directly. For `l2` and `ip` there is no honest conversion — the
    /// scale is unbounded and depends on the vectors' magnitude — so the
    /// candidate's *position* in the collection's own ranking becomes its
    /// relevance. Ranks are comparable where scales are not; the same reasoning
    /// E4 applies to fusion.
    ///
    /// Candidates whose vector did not come back cannot be compared to anything.
    /// They keep their places rather than disappearing: losing a result because
    /// its embedding was missing would be a worse failure than showing it out
    /// of order.
    ///
    /// **Место — по рангу слияния, а не в конце списка**. Текстовая
    /// половина гибридного поиска приходит без векторов: `$contains` отдаёт
    /// документы, а не эмбеддинги. Пока такие кандидаты сваливались в хвост,
    /// усечение до `n_results` выбрасывало их **все** — то есть при включённом
    /// разнообразии текстовый поиск не влиял на выдачу вообще. Живой замер:
    /// на запросе «ФНС сервера» текстовая половина нашла 200 документов,
    /// слияние дало 377 кандидатов — и выдача совпала с той, где текстового
    /// поиска не было вовсе, до последнего идентификатора.
    static func diversifying(
        _ hits: [RetrievalHit], count: Int, lambda: Double, metric: DistanceMetric?
    ) -> (hits: [RetrievalHit], note: String?) {
        let withVectors = hits.enumerated().filter { $0.element.embedding?.isEmpty == false }
        guard withVectors.count > 1 else {
            return (hits, String(localized: "векторов кандидатов нет — переупорядочивать нечем"))
        }

        let total = withVectors.count
        let candidates = withVectors.enumerated().map { position, entry -> MaximalMarginalRelevance.Candidate in
            // Сначала — оценка, если её кто-то уже поправил.
            let bounded = entry.element.relevance
                ?? entry.element.distance.flatMap { metric?.similarity(forDistance: $0) }
            // Without a bounded scale: first in the pool is 1, last is near 0.
            let byRank = total > 1 ? 1 - Double(position) / Double(total) : 1
            return MaximalMarginalRelevance.Candidate(
                id: entry.element.id,
                relevance: bounded ?? byRank,
                vector: entry.element.embedding ?? []
            )
        }

        let order = MaximalMarginalRelevance.select(candidates, count: count, lambda: lambda)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let byID: [String: RetrievalHit] = Dictionary(
            hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let chosen = order.compactMap { byID[$0] }

        // Кандидаты без вектора — по рангу среди **уцелевших**, а не среди
        // всех, кто пришёл. MMR прореживает векторную половину (из двухсот
        // остаётся десять), и считать место по выбывшим значит отправить
        // текстовую половину в хвост: у первого текстового кандидата было
        // десять векторных впереди, из которых MMR оставил одного.
        var vectorless: [Int: [RetrievalHit]] = [:]
        var survivorsSoFar = 0
        for hit in hits {
            if position[hit.id] != nil {
                survivorsSoFar += 1
                continue
            }
            guard hit.embedding?.isEmpty != false else { continue }
            vectorless[survivorsSoFar, default: []].append(hit)
        }

        // Ключи `vectorless` лежат в 0…chosen.count — счётчик растёт только
        // на выбранных, — поэтому цикл ниже разбирает их все, и «хвоста
        // на всякий случай» здесь быть не может.
        var result: [RetrievalHit] = vectorless[0] ?? []
        for (index, hit) in chosen.enumerated() {
            result.append(hit)
            result += vectorless[index + 1] ?? []
        }
        let mixed = result.count - chosen.count
        var note = String(localized: "λ \(String(format: "%.2f", lambda)), из \(hits.count) кандидатов оставлено \(result.count)")
        if mixed > 0 {
            note += String(localized: ", из них без вектора \(mixed.plainDigits) — расставлены по рангу слияния")
        }
        return (result, note)
    }

    // MARK: - Stage 6: the chunks that stood next to the match

    /// Attaches neighbouring chunks so a result does not start mid-thought.
    ///
    /// Every neighbour of the whole page comes back in **one** request. One call
    /// per result would turn a page of ten into eleven round trips, and the
    /// section exists precisely because chunk boundaries cut sentences in half —
    /// this must not become the expensive part of a search.
    ///
    /// Ranking is untouched: the distance stays the matched chunk's. A result
    /// ranked by its expanded text would be ranked by its neighbours.
    func expandingContext(
        _ hits: [RetrievalHit], window: Int, collectionID: String
    ) async throws -> (hits: [RetrievalHit], note: String?) {
        // Only chunks that say both where they came from and where they sat can
        // have neighbours at all. A document added by hand has neither.
        let addressable = hits.filter { $0.sourceFile != nil && $0.chunkIndex != nil }
        guard !addressable.isEmpty else {
            return (hits, String(localized: "у результатов нет source_file и chunk_index"))
        }

        var wanted: [String: Set<Int>] = [:]
        for hit in addressable {
            guard let file = hit.sourceFile, let index = hit.chunkIndex else { continue }
            for offset in -window...window where offset != 0 {
                let neighbour = index + offset
                guard neighbour >= 0 else { continue }
                wanted[file, default: []].insert(neighbour)
            }
        }
        // Chunks the page already holds need no fetching, and asking for them
        // would only make the request bigger.
        for hit in addressable {
            guard let file = hit.sourceFile, let index = hit.chunkIndex else { continue }
            wanted[file]?.remove(index)
        }
        wanted = wanted.filter { !$0.value.isEmpty }
        guard !wanted.isEmpty else { return (hits, String(localized: "соседей запрашивать не пришлось")) }

        let branches = wanted.sorted { $0.key < $1.key }.map { file, indices in
            FilterNode.group(.and, [
                .leaf(MetadataCondition(field: "source_file", op: .equals, value: file)),
                .leaf(MetadataCondition(
                    field: "chunk_index", op: .inList,
                    value: indices.sorted().map(String.init).joined(separator: ", ")
                )),
            ])
        }
        var filter = DocumentFilter()
        filter.root = .group(.or, branches)
        let total = wanted.values.reduce(0) { $0 + $1.count }

        let fetched = try await database.documents(
            collectionID: collectionID, matching: filter, limit: total
        )
        var byPosition: [String: DocumentRecord] = [:]
        for record in fetched {
            guard case .string(let file)? = record.metadata?["source_file"],
                  case .int(let index)? = record.metadata?["chunk_index"] else { continue }
            byPosition["\(file)\u{0}\(index)"] = record
        }

        // Where the page's own results sit, so a chunk that is already a result
        // is not attached to its neighbour as context — and does not count as a
        // hole either.
        var onPage: Set<String> = []
        for hit in addressable {
            guard let file = hit.sourceFile, let index = hit.chunkIndex else { continue }
            onPage.insert("\(file)\u{0}\(index)")
        }

        var attached = 0
        let result = hits.map { hit -> RetrievalHit in
            guard let file = hit.sourceFile, let index = hit.chunkIndex else { return hit }
            var neighbours: [RetrievalHit] = []
            // Outward from the match, stopping at the first gap: a missing
            // index means the chunk was never written or was removed, and
            // jumping over it would join two pieces of text that never touched
            //.
            for direction in [-1, 1] {
                for step in 1...window {
                    let position = index + direction * step
                    guard position >= 0 else { break }
                    let key = "\(file)\u{0}\(position)"
                    // Already on the page as a result of its own. Not shown
                    // twice — and not a gap: the text is there, so the walk
                    // carries on past it.
                    if onPage.contains(key) { continue }
                    guard let record = byPosition[key] else { break }
                    neighbours.append(RetrievalHit(
                        id: record.id, document: record.document, metadata: record.metadata,
                        distance: nil, sources: hit.sources, role: .context, contextKind: .neighbour
                    ))
                    attached += 1
                }
            }
            guard !neighbours.isEmpty else { return hit }
            var expanded = hit
            // In reading order, so the card can lay them out around the match.
            expanded.context += neighbours.sorted { ($0.chunkIndex ?? 0) < ($1.chunkIndex ?? 0) }
            return expanded
        }
        return (result, String(localized: "присоединено соседних чанков: \(attached), запросов: 1"))
    }

    // MARK: - Stage 7: the model reorders what is left

    /// Sends the head of the list to a chat model and applies its order.
    ///
    /// Only the head: twenty is the cap the section fixes, and a longer prompt
    /// is both slower and worse. The tail keeps its place — it was never shown
    /// to the model, so nothing has been said about it.
    ///
    /// The text sent is the result's own, without the context attached in stage
    /// 6: ranking by the surroundings would rank by the surroundings.
    private func reranking(
        _ hits: [RetrievalHit], profile: SearchProfile, query: String
    ) async throws -> (hits: [RetrievalHit], note: String) {
        guard !profile.rerankModel.isEmpty else { throw RerankError.noModelChosen }
        let head = Array(hits.prefix(Reranker.maximumCandidates))
        let tail = Array(hits.dropFirst(head.count))
        guard head.count > 1 else {
            return (hits, String(localized: "переранжировать нечего: кандидат один"))
        }

        switch profile.rerankMode {
        case .chatSchema:
            guard let complete else { throw RerankError.noModelChosen }
            // Промпт укладывается в контекст **до** отправки. Иначе один движок
            // отвечает 400, а другой молча обрезает список — и ранжирование
            // выходит по обрубку, о чём никто не узнаёт.
            let fitted = Reranker.fit(
                documents: head.map { $0.document ?? "" },
                query: query, template: profile.rerankPrompt,
                contextTokens: rerankContextTokens,
                charactersPerToken: rerankCharactersPerToken
                    ?? TokenEstimator.pessimisticCharactersPerToken,
                ratioWasMeasured: rerankCharactersPerToken != nil
            )
            guard !fitted.documents.isEmpty else {
                throw RerankError.contextTooSmall(tokens: rerankContextTokens ?? 0)
            }
            // Отброшенные хвостом кандидаты остаются на своих местах, как всё,
            // о чём модель не высказалась.
            let asked = Array(head.prefix(fitted.documents.count))
            let unasked = Array(head.dropFirst(asked.count))
            let prompt = Reranker.prompt(
                template: profile.rerankPrompt, query: query, documents: fitted.documents
            )
            let answer = try await complete(prompt, profile.rerankModel, Reranker.schema)
            let verdicts = try Reranker.verdicts(from: answer, count: asked.count)
            return (
                Reranker.reordered(asked, by: verdicts) + unasked + tail,
                String(localized: "модель \(profile.rerankModel), кандидатов \(asked.count), один вызов по схеме")
                    + (fitted.note.map { ", \($0)" } ?? "")
            )

        case .crossEncoder:
            guard let completePlain else { throw RerankError.noPlainCompleter }
            let plainRatio = rerankCharactersPerToken ?? TokenEstimator.pessimisticCharactersPerToken
            guard CrossEncoderReranker.documentLimit(
                contextTokens: rerankContextTokens, charactersPerToken: plainRatio
            ) > 0 else {
                throw RerankError.contextTooSmall(tokens: rerankContextTokens ?? 0)
            }
            // По вызову на фрагмент — так устроены переранжировщики. Дороже
            // одного вызова, зато это единственный способ, которым такая
            // модель вообще умеет отвечать.
            let instruction = CrossEncoderReranker.instruction(from: profile.rerankInstruction)
            var verdicts: [Bool?] = []
            for hit in head {
                let answer = try await completePlain(
                    CrossEncoderReranker.prompt(
                        query: query, document: hit.document ?? "", instruction: instruction,
                        contextTokens: rerankContextTokens, charactersPerToken: plainRatio
                    ),
                    profile.rerankModel
                )
                verdicts.append(CrossEncoderReranker.verdict(answer))
            }
            guard verdicts.contains(where: { $0 != nil }) else { throw RerankError.nothingUsable }
            let yes = verdicts.filter { $0 == true }.count
            let unclear = verdicts.filter { $0 == nil }.count
            return (
                CrossEncoderReranker.reordered(head, verdicts: verdicts) + tail,
                String(localized: "переранжировщик \(profile.rerankModel): подошло \(yes) из \(head.count), вызовов \(head.count)")
                    + (unclear > 0 ? String(localized: ", не понят ответ по \(unclear)") : "")
            )
        }
    }

    // MARK: - Diagnostics for stages that did not run

    /// A stage the profile switched off, or one the collection cannot support.
    private func off(
        _ stage: RetrievalStage, count: Int, skipped: [RetrievalStage: String]
    ) -> RetrievalDiagnostics.StageReport {
        .init(
            stage: stage, ran: false, inputCount: count, outputCount: count,
            note: skipped[stage] ?? String(localized: "в профиле не включено")
        )
    }

    /// A stage whose queue item has not come up yet. Said plainly rather than
    /// dressed as «выключено»: the two are different answers to «почему не
    /// сработало».
    private func unimplemented(_ stage: RetrievalStage, count: Int) -> RetrievalDiagnostics.StageReport {
        .init(
            stage: stage, ran: false, inputCount: count, outputCount: count,
            note: String(localized: "стадия ещё не реализована")
        )
    }
}
