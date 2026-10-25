import Foundation

/// Поиск сразу по нескольким коллекциям.
///
/// Сценарий, ради которого это делается: «ищу по документации, по коду
/// и по заметкам одновременно». Новой механики он не требует — вся она уже
/// есть после этапа 10:
///
/// * **Вектор считается по разу на модель, а не на коллекцию.** Три коллекции
///   на одной модели — это один вызов LM Studio, а не три. Ровно то же
/// правило, что у стенда оценки, и по той же причине: локальная
///   модель — самое дорогое, что есть в приложении.
/// * **Списки сливаются тем же RRF, что и гибридный поиск**. Ранги
///   сопоставимы между коллекциями даже с разными метриками, а расстояния —
///   нет: у `l2` шкала не ограничена вовсе, и складывать её с косинусной
///   значило бы складывать сантиметры с килограммами. Ради этого RRF
///   и выбирался.
/// * **Каждая коллекция ищется своим профилем**: у документации
///   переранжирование может быть включено, у заметок — нет, и навязывать им
///   общие настройки значило бы искать не так, как человек настроил.
public struct MultiCollectionSearch: Sendable {
    /// Одна коллекция в запросе.
    public struct Target: Sendable {
        public let collectionID: String
        public let collectionName: String
        /// Модель, привязанная к коллекции. **Ключ дедупликации вектора**
        /// вместе с текстом запроса.
        public let model: String
        public let metric: DistanceMetric?
        public let profile: SearchProfile
        /// Вес коллекции при слиянии. Единица у всех — пока человек
        /// не решил иначе.
        public let weight: Double
        /// Сколько результатов взять из этой коллекции, если больше, чем
        /// просит выдача. Ставит сам поиск — под пул переранжирования;
        /// `nil` — сколько просили.
        public private(set) var poolSize: Int?

        /// Сколько результатов спрашивать у коллекции при просьбе `requested`.
        public func results(forRequested requested: Int) -> Int {
            max(requested, poolSize ?? 0)
        }

        public init(
            collectionID: String,
            collectionName: String,
            model: String,
            metric: DistanceMetric? = nil,
            profile: SearchProfile,
            weight: Double = 1
        ) {
            self.collectionID = collectionID
            self.collectionName = collectionName
            self.model = model
            self.metric = metric
            self.profile = profile
            self.weight = weight
        }

        /// Та же цель, но без переранжирования в профиле.
        ///
        /// Каждая коллекция ищется без стадии 7, потому что спрашивают
        /// модель **после** слияния и один раз про всех. Снимается
        /// здесь, а не у вызывающего: гарантия «модель не спросят дважды»
        /// обязана жить в одном месте.
        ///
        /// И с пулом, если переранжирование спросят после слияния: коллекция,
        /// обрезанная до `nResults`, не давала модели кандидатов глубже
        /// выдачи — а треть выигрыша стадии приходит именно оттуда.
        /// Одна коллекция с тем же профилем переранжирует пул в двадцать
        /// пять, и несколько коллекций обязаны видеть не меньше.
        func withoutRerank(pool: Int? = nil) -> Target {
            var stripped = profile
            stripped.rerankEnabled = false
            var target = Target(
                collectionID: collectionID, collectionName: collectionName,
                model: model, metric: metric, profile: stripped, weight: weight
            )
            target.poolSize = pool
            return target
        }
    }

    /// Что случилось с одной коллекцией — по строке на каждую.
    ///
    /// Отдельно от результатов: коллекция, которая не ответила, обязана быть
    /// видна. Молчаливо выпавшая из выдачи коллекция выглядит как коллекция,
    /// в которой ничего не нашлось, — и человек делает из этого неверный
    /// вывод о своих данных.
    public struct CollectionReport: Sendable, Hashable {
        public let name: String
        public let found: Int
        public let seconds: Double
        /// Причина, по которой коллекция не искалась или не ответила.
        public let failure: String?

        public init(name: String, found: Int, seconds: Double, failure: String? = nil) {
            self.name = name
            self.found = found
            self.seconds = seconds
            self.failure = failure
        }
    }

    public struct Answer: Sendable {
        public let hits: [RetrievalHit]
        public let collections: [CollectionReport]
        /// Сколько раз считался вектор запроса. Столько же, сколько разных
        /// моделей, — и это проверяется тестом.
        public let embeddingCalls: Int
        public let seconds: Double
        /// Что стало со стадией 7 на слитой выдаче: как переранжировали или
        /// почему не стали. `nil` — никто её и не просил.
        ///
        /// Не молчать об этом — то же правило, что у конвейера:
        /// список, который никто не переранжировал, выданный за
        /// переранжированный, хуже отсутствия стадии.
        public let rerankNote: String?
        /// То же для агента, по-английски: ответ MCP читает модель,
        /// а `rerankNote` писался человеку у экрана.
        public let rerankAgentNote: String?

        public init(
            hits: [RetrievalHit], collections: [CollectionReport],
            embeddingCalls: Int, seconds: Double, rerankNote: String? = nil,
            rerankAgentNote: String? = nil
        ) {
            self.hits = hits
            self.collections = collections
            self.embeddingCalls = embeddingCalls
            self.seconds = seconds
            self.rerankNote = rerankNote
            self.rerankAgentNote = rerankAgentNote
        }

        /// Итог одной строкой для агента — по-английски. `line` — для журнала
        /// и экрана; в ответ MCP он уходил как есть, и модель получала
        /// русскую строку посреди английского ответа.
        public var agentLine: String {
            let answered = collections.filter { $0.failure == nil }
            let failed = collections.filter { $0.failure != nil }
            var text = "Searched \(answered.count.plainDigits) collections, found \(hits.count.plainDigits), query vectors computed \(embeddingCalls.plainDigits)"
            if !failed.isEmpty {
                text += "; did not answer: \(failed.map(\.name).joined(separator: ", "))"
            }
            if let rerankAgentNote { text += "; \(rerankAgentNote)" }
            return text + "."
        }

        public var line: String {
            let answered = collections.filter { $0.failure == nil }
            let failed = collections.filter { $0.failure != nil }
            var text = String(localized: "коллекций \(answered.count.plainDigits), найдено \(hits.count.plainDigits), векторов запроса \(embeddingCalls.plainDigits)")
            if !failed.isEmpty {
                text += String(localized: "; не ответили: \(failed.map(\.name).joined(separator: ", "))")
            }
            if let rerankNote { text += "; \(rerankNote)" }
            return text
        }
    }

    /// Текст и модель на входе, вектор на выходе — как у стенда оценки.
    public typealias Embedder = @Sendable (_ text: String, _ model: String) async throws -> [Double]
    /// Один поиск по одной коллекции. Вектор уже посчитан — в этом и смысл.
    public typealias Searcher = @Sendable (
        _ target: Target, _ query: String, _ vector: [Double]
    ) async throws -> RetrievalOutcome

    private let embed: Embedder
    private let search: Searcher
    private let fusionK: Double
    /// Чем переранжировать слитую выдачу. `nil` — нечем, и об этом скажут
    /// вслух, если профили стадию просили.
    private let rerank: RerankStage?

    public init(
        embed: @escaping Embedder,
        search: @escaping Searcher,
        fusionK: Double = ReciprocalRankFusion.defaultK,
        rerank: RerankStage? = nil
    ) {
        self.embed = embed
        self.search = search
        self.fusionK = fusionK
        self.rerank = rerank
    }

    // MARK: - Стадия 7 на слитой выдаче

    /// Что делать со слитой выдачей: чьим профилем спрашивать модель — или
    /// не спрашивать и почему.
    public struct RerankPlan: Sendable {
        /// Профиль, чьими настройками спрашивают. `nil` — не спрашивают.
        public let profile: SearchProfile?
        public let note: String?
        /// То же — для агента, по-английски.
        public var agentNote: String? = nil
    }

    /// Правило одно: **все** выбранные коллекции должны просить одного и того
    /// же переранжирования.
    ///
    /// Иначе пришлось бы решать за человека, чей профиль главнее, — и
    /// спрашивать модель настройками одной коллекции про документы другой,
    /// которая эту стадию у себя выключила. Молчаливого старшинства в этом
    /// приложении нет нигде, не будет и здесь: несогласие названо словами,
    /// а выдача остаётся слитой рангами.
    public static func rerankPlan(targets: [Target]) -> RerankPlan {
        let asking = targets.filter { RerankStage.Settings(profile: $0.profile).enabled }
        guard !asking.isEmpty else { return RerankPlan(profile: nil, note: nil) }
        guard asking.count == targets.count else {
            let silent = targets
                .filter { !RerankStage.Settings(profile: $0.profile).enabled }
                .map(\.collectionName)
            return RerankPlan(
                profile: nil,
                note: String(localized: "переранжирование просят не все коллекции (без него: \(silent.joined(separator: ", "))) — выдача слита рангами"),
                agentNote: "not every collection asks for reranking (without it: \(silent.joined(separator: ", "))), so the lists were merged by rank"
            )
        }
        guard Set(asking.map { RerankStage.Settings(profile: $0.profile) }).count == 1 else {
            return RerankPlan(
                profile: nil,
                note: String(localized: "коллекции просят разного переранжирования — выдача слита рангами"),
                agentNote: "the collections ask for different reranking, so the lists were merged by rank"
            )
        }
        return RerankPlan(profile: asking[0].profile, note: nil)
    }

    public func run(query: String, targets: [Target], nResults: Int = 10) async -> Answer {
        let started = Date()
        guard !targets.isEmpty else {
            return Answer(hits: [], collections: [], embeddingCalls: 0, seconds: 0)
        }

        // Вектор на «модель + текст, уходящий в модель», а не на коллекцию
        //. Одной модели мало: приставка к запросу живёт в профиле,
        // и у двух целей на одной модели она может быть разной — общий
        // вектор дал бы одной из них выдачу по чужому запросу.
        struct VectorKey: Hashable {
            let model: String
            let text: String
        }
        var vectors: [VectorKey: [Double]] = [:]
        var calls = 0
        var reports: [CollectionReport] = []
        var lists: [(target: Target, hits: [RetrievalHit])] = []

        // Пул под стадию 7 шире выдачи: модель должна увидеть тех кандидатов,
        // до которых десятка не достаёт, — треть выигрыша приходит именно
        // оттуда. Считается до поиска: каждая коллекция обязана
        // отдать столько, иначе пул слитой выдачи был бы не шире её суммы.
        let plan = Self.rerankPlan(targets: targets)
        let poolLimit = plan.profile.map {
            max(nResults, Reranker.candidateCount($0.rerankCandidates))
        } ?? nResults

        for target in targets {
            let collectionStarted = Date()
            do {
                // Тот же текст, что считает живой поиск внутри конвейера
                //: здесь вектор передаётся готовым, и конвейер свою
                // приставку применить уже не сможет — значит применить её
                // обязаны мы.
                let asked = target.profile.embeddedQuery(query)
                let key = VectorKey(model: target.model, text: asked)
                let vector: [Double]
                if let known = vectors[key] {
                    vector = known
                } else {
                    vector = try await embed(asked, target.model)
                    vectors[key] = vector
                    calls += 1
                }
                // Без стадии 7: её спросят один раз после слияния.
                let outcome = try await search(
                    target.withoutRerank(pool: plan.profile == nil ? nil : poolLimit), query, vector
                )
                lists.append((target, outcome.hits))
                reports.append(CollectionReport(
                    name: target.collectionName, found: outcome.hits.count,
                    seconds: Date().timeIntervalSince(collectionStarted)
                ))
            } catch {
                // Одна коллекция не ответила — остальные обязаны ответить.
                // Поиск по трём коллекциям, падающий целиком из-за одной
                // отключённой, хуже поиска по одной.
                reports.append(CollectionReport(
                    name: target.collectionName, found: 0,
                    seconds: Date().timeIntervalSince(collectionStarted),
                    failure: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ))
            }
        }

        var fused = Self.fuse(lists, k: fusionK, limit: poolLimit)
        var note = plan.note
        var agentNote = plan.agentNote

        if let profile = plan.profile {
            if let rerank, rerank.isReady(for: profile.rerankMode) {
                do {
                    let result = try await rerank.run(fused, profile: profile, query: query)
                    fused = result.hits
                    note = result.note
                    agentNote = "the merged list was reranked by the model"
                } catch {
                    // Та же осторожность, что у конвейера: модель, которая
                    // отказала, не забирает с собой поиск — список остаётся
                    // слитым рангами, а причина попадает в ответ.
                    note = String(localized: "переранжирование не выполнено: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                    agentNote = "the merged list was not reranked: " + ((error as? MCPReadableError)?.mcpReason ?? "the model did not answer")
                }
            } else {
                note = profile.rerankMode == .crossEncoder
                    ? String(localized: "переранжировать нечем: прямой вызов модели этому поиску не передан")
                    : String(localized: "переранжировать нечем: чат-модель этому поиску не передана")
                agentNote = "the merged list was not reranked: no model is connected to this search for that"
            }
        }

        return Answer(
            hits: Array(fused.prefix(max(1, nResults))), collections: reports,
            embeddingCalls: calls, seconds: Date().timeIntervalSince(started),
            rerankNote: note, rerankAgentNote: agentNote
        )
    }

    // MARK: - Слияние

    /// Ключ документа в слиянии: коллекция плюс идентификатор.
    ///
    /// Без имени коллекции два разных документа с одинаковым `id` — а таких
    /// сколько угодно: идентификатор считается от пути внутри источника —
    /// слились бы в один, и один из них исчез бы из выдачи молча.
    static func key(collection: String, id: String) -> String {
        "\(collection)\u{0}\(id)"
    }

    /// Слияние списков по рангам.
    ///
    /// **Дубли между коллекциями здесь не склеиваются, и это не упущение.**
    /// Документ живёт в одной коллекции; одинаковый `id` в двух — это два
    /// разных документа, потому что идентификатор считается от пути внутри
    /// источника и совпадает сплошь и рядом. Склеить их значило бы потерять
    /// один из них молча. Поэтому RRF здесь делает то, ради чего он и нужен:
    /// **чередует** списки по местам, а не складывает расстояния, шкалы
    /// которых у разных метрик несравнимы.
    static func fuse(
        _ lists: [(target: Target, hits: [RetrievalHit])], k: Double, limit: Int
    ) -> [RetrievalHit] {
        var scores: [String: Double] = [:]
        var byKey: [String: RetrievalHit] = [:]
        var firstSeen: [String: Int] = [:]
        var counter = 0

        for list in lists {
            for (position, hit) in list.hits.enumerated() {
                let key = Self.key(collection: list.target.collectionName, id: hit.id)
                // Та же формула, что в `ReciprocalRankFusion`: 1/(k + позиция),
                // с весом источника. Здесь другое пространство ключей, поэтому
                // и считается здесь — но арифметика обязана совпадать, иначе
                // «сливается тем же RRF» станет неправдой.
                scores[key, default: 0] += list.target.weight / (k + Double(position + 1))
                if byKey[key] == nil {
                    var annotated = hit
                    annotated.collectionName = list.target.collectionName
                    byKey[key] = annotated
                    firstSeen[key] = counter
                    counter += 1
                }
            }
        }

        return scores
            .sorted { left, right in
                left.value == right.value
                    ? (firstSeen[left.key] ?? 0) < (firstSeen[right.key] ?? 0)
                    : left.value > right.value
            }
            .prefix(max(1, limit))
            .compactMap { byKey[$0.key] }
    }
}
