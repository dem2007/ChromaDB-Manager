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

        public var line: String {
            let answered = collections.filter { $0.failure == nil }
            let failed = collections.filter { $0.failure != nil }
            var text = String(localized: "коллекций \(answered.count.plainDigits), найдено \(hits.count.plainDigits), векторов запроса \(embeddingCalls.plainDigits)")
            if !failed.isEmpty {
                text += String(localized: "; не ответили: \(failed.map(\.name).joined(separator: ", "))")
            }
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

    public init(
        embed: @escaping Embedder,
        search: @escaping Searcher,
        fusionK: Double = ReciprocalRankFusion.defaultK
    ) {
        self.embed = embed
        self.search = search
        self.fusionK = fusionK
    }

    public func run(query: String, targets: [Target], nResults: Int = 10) async -> Answer {
        let started = Date()
        guard !targets.isEmpty else {
            return Answer(hits: [], collections: [], embeddingCalls: 0, seconds: 0)
        }

        // Вектор на модель, а не на коллекцию.
        var vectors: [String: [Double]] = [:]
        var calls = 0
        var reports: [CollectionReport] = []
        var lists: [(target: Target, hits: [RetrievalHit])] = []

        for target in targets {
            let collectionStarted = Date()
            do {
                let vector: [Double]
                if let known = vectors[target.model] {
                    vector = known
                } else {
                    vector = try await embed(query, target.model)
                    vectors[target.model] = vector
                    calls += 1
                }
                let outcome = try await search(target, query, vector)
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

        let fused = Self.fuse(lists, k: fusionK, limit: nResults)
        return Answer(
            hits: fused, collections: reports, embeddingCalls: calls,
            seconds: Date().timeIntervalSince(started)
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
