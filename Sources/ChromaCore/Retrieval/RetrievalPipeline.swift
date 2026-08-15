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
            vector = try await embed(request.text)
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

        var hits = vectorHits
        var candidateNote = pool == nResults
            ? String(localized: "запрошено \(pool) — пул не нужен, дальше ничего не отсеивает")
            : String(localized: "запрошено \(pool)")
        if !wantsVector { candidateNote = String(localized: "векторный поиск выключен") }
        if let levelNote { candidateNote += ", \(levelNote)" }
        if let textNote { candidateNote += ", \(textNote)" }
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
            let marked = Self.applyingMarks(hits)
            hits = marked.hits
            diagnostics.stages.append(.init(
                stage: .marks, ran: true, inputCount: before, outputCount: hits.count,
                duration: Date().timeIntervalSince(marksStarted),
                note: marked.note
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
        let hits = ranked.enumerated().map { position, entry in
            RetrievalHit(
                id: entry.record.id, document: entry.record.document,
                metadata: entry.record.metadata, distance: nil, sources: [.text],
                placements: [SourcePlacement(source: .text, position: position + 1)]
            )
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

        let hits = fused.compactMap { entry -> RetrievalHit? in
            guard var hit = byID[entry.id] else { return nil }
            hit.sources = entry.sources
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
    /// They keep their places at the end rather than disappearing: losing a
    /// result because its embedding was missing would be a worse failure than
    /// showing it out of order.
    static func diversifying(
        _ hits: [RetrievalHit], count: Int, lambda: Double, metric: DistanceMetric?
    ) -> (hits: [RetrievalHit], note: String?) {
        let withVectors = hits.enumerated().filter { $0.element.embedding?.isEmpty == false }
        guard withVectors.count > 1 else {
            return (hits, String(localized: "векторов кандидатов нет — переупорядочивать нечем"))
        }

        let total = withVectors.count
        let candidates = withVectors.enumerated().map { position, entry -> MaximalMarginalRelevance.Candidate in
            let bounded = entry.element.distance.flatMap { metric?.similarity(forDistance: $0) }
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
        var result = order.compactMap { byID[$0] }
        // Everything MMR did not look at, in the order it arrived.
        result += hits.filter { position[$0.id] == nil && $0.embedding?.isEmpty != false }
        return (
            result,
            String(localized: "λ \(String(format: "%.2f", lambda)), из \(hits.count) кандидатов оставлено \(result.count)")
        )
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
