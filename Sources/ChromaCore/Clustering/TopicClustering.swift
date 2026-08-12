import Foundation

/// Тематические кластеры коллекции.
///
/// Реализовано после прямого согласия пользователя, полученного в той
/// формулировке, которую требует K2.2: «нужен ли список тем с числами и
/// примерами — без какой-либо графической проекции векторов». Ответ был
/// утвердительным, и границы ответа — это границы этого файла: **список, а не
/// картинка**. Ни здесь, ни в интерфейсе нет и не появится 2D-раскладки,
/// PCA, UMAP, t-SNE или диаграммы рассеяния — запрет 6.4 и L5 остаются в силе.
///
/// **Читает и только читает.** Тип принимает `InspectionReader` — протокол, в
/// котором нет ни одного метода записи. Требование K2.3 «в метаданные
/// документов не записывается» держится не договорённостью, а тем, что писать
/// этому коду нечем.
///
/// **Векторы берутся из базы.** Повторный эмбеддинг не выполняется: он стоил бы
/// дороже переиндексации и занял бы локальную модель ради отчёта.
public struct TopicClustering: Sendable {
    /// Промпт и схема на входе, ответ модели на выходе.
    ///
    /// Замыканием, как у `ModelJudge`: ядро не знает про LM Studio, а тесты
    /// подставляют свой ответ, не поднимая ни модели, ни сети.
    public typealias Namer = @Sendable (_ prompt: String, _ schema: ChatJSONSchema) async throws -> String

    /// Сколько ждать ответа модели на одну тему — пять минут вместо общих
    /// трёх.
    ///
    /// Свой срок, а не общий `timeouts.chat`: у этой задачи он расходуется
    /// иначе. Первый из двух десятков запросов приходит в модель, которая ещё
    /// не загружена в память, и большая модель поднимается минутами; «думающая»
    /// модель вдобавок тратит на короткое название столько же рассуждения,
    /// сколько на длинный ответ. Оборванный по сроку ответ означает
    /// пронумерованную тему и строку в оговорках — то есть потерянную работу
    /// там, где нужно было просто подождать.
    ///
    /// Настройку `timeouts.chat` это не трогает: там срок для чанкинга, где
    /// запросов тысячи и ждать каждый по пять минут нельзя.
    public static let namingTimeout: TimeInterval = 300

    public struct Options: Sendable, Hashable {
        /// по умолчанию до 10 000 документов.
        public var sampleSize: Int
        /// `nil` — число тем подбирается само.
        public var clusterCount: Int?
        /// зерно фиксировано, чтобы прогон повторялся.
        public var seed: UInt64
        public var examplesPerTopic: Int
        /// Сколько примеров показать среди неотнесённых.
        public var unassignedExamples: Int

        public init(
            sampleSize: Int = 10_000,
            clusterCount: Int? = nil,
            seed: UInt64 = UInt64(ChatGenerationSettings.defaultSeed),
            examplesPerTopic: Int = 5,
            unassignedExamples: Int = 10
        ) {
            self.sampleSize = max(10, sampleSize)
            self.clusterCount = clusterCount
            self.seed = seed
            self.examplesPerTopic = max(1, examplesPerTopic)
            self.unassignedExamples = max(1, unassignedExamples)
        }
    }

    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let stage: String
    }

    static let pageSize = 500
    /// Векторы просим партиями: список из десяти тысяч идентификаторов в одном
    /// запросе — это мегабайты в строке URL-запроса и минуты ожидания первого
    /// байта.
    static let embeddingBatch = 200

    private let reader: any InspectionReader
    private let log: LogHandler

    public init(reader: any InspectionReader, log: @escaping LogHandler = noopLogHandler) {
        self.reader = reader
        self.log = log
    }

    public func run(
        collection: ChromaCollection,
        options: Options = Options(),
        namer: (model: String, call: Namer)? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> TopicReport {
        let started = Date()
        let collectionID = collection.id
        let total = (try? await reader.count(collectionID: collectionID)) ?? 0
        var notes: [String] = []

        // 1. Документы выборки — **только их идентификаторы**.
        //
        // Тексты всей выборки в памяти не нужны: показывается по нескольку
        // примеров на тему, то есть сотня строк из десятков тысяч. Прежде
        // страница за страницей складывалась целиком, и выборка в 58 000
        // документов держала сотни мегабайт текста рядом с полугигабайтом
        // векторов — на этом приложение и переставало отвечать. Тексты
        // отобранных примеров дочитываются в конце, по идентификаторам.
        var sampleIDs: [String] = []
        var offset = 0
        while sampleIDs.count < options.sampleSize {
            try Task.checkCancellation()
            let limit = min(Self.pageSize, options.sampleSize - sampleIDs.count)
            let page = try await reader.documents(collectionID: collectionID, limit: limit, offset: offset)
            guard !page.isEmpty else { break }
            offset += page.count
            sampleIDs.append(contentsOf: page.map(\.id))
            progress?(Progress(
                done: sampleIDs.count, total: min(total, options.sampleSize),
                stage: String(localized: "Чтение документов")
            ))
        }
        let examined = sampleIDs.count
        guard examined >= 2 else {
            throw ClusteringError.tooFewDocuments(examined)
        }

        // 2. Векторы — из базы, партиями.
        var vectors: [[Double]] = []
        var vectorIDs: [String] = []
        var dimension = collection.effectiveDimension ?? 0
        var withoutVector = 0
        var position = 0
        while position < sampleIDs.count {
            try Task.checkCancellation()
            let slice = Array(sampleIDs[position..<min(position + Self.embeddingBatch, sampleIDs.count)])
            position += slice.count
            let found = try await reader.embeddings(collectionID: collectionID, ids: slice)
            for id in slice {
                guard let vector = found[id], !vector.isEmpty else {
                    withoutVector += 1
                    continue
                }
                if dimension == 0 { dimension = vector.count }
                guard vector.count == dimension else {
                    withoutVector += 1
                    continue
                }
                vectors.append(vector)
                vectorIDs.append(id)
            }
            progress?(Progress(
                done: position, total: sampleIDs.count,
                stage: String(localized: "Чтение векторов")
            ))
        }
        if withoutVector > 0 {
            notes.append(String(localized: "Без вектора или с вектором другой длины: \(withoutVector.plainDigits) документов — в кластеризацию они не вошли."))
        }
        guard vectors.count >= 2, dimension > 0 else {
            throw ClusteringError.tooFewVectors(vectors.count)
        }

        // 3. Разбиение.
        try Task.checkCancellation()
        progress?(Progress(done: 0, total: 1, stage: String(localized: "Кластеризация")))
        let points = VectorSet(vectors: vectors, dimension: dimension)
        // Нулевой вектор набор отбрасывает — и вместе с ним ломается
        // соответствие «точка ↔ документ». Поэтому идентификаторы и тексты
        // раскладываются по тому же списку `keptIndexes`, а не по своему
        // правилу: иначе тема получила бы примеры от чужих строк.
        let ids = points.keptIndexes.map { vectorIDs[$0] }
        if points.count < vectors.count {
            notes.append(String(localized: "Нулевых векторов: \((vectors.count - points.count).plainDigits) — у них нет направления, и в кластеризацию они не вошли."))
        }
        guard points.count >= 2 else { throw ClusteringError.tooFewVectors(points.count) }

        let chosen: Int
        if let requested = options.clusterCount {
            chosen = max(2, min(requested, points.count))
        } else {
            let selection = KMeans.suggestK(
                points, seed: options.seed, shouldStop: { Task.isCancelled }
            )
            try Task.checkCancellation()
            chosen = selection.k
            // Все измеренные значения в журнал, а не только выбранное: вопрос
            // «почему тем именно столько» должен иметь ответ, который можно
            // посмотреть.
            log(.info, "Темы", "Число тем по умолчанию: \(selection.k). Силуэт — \(selection.line)")
            if selection.coarseSplitDominates {
                // «чем на \(k) тем» — ловушка русского числительного: при 21 и
                // 24 нужны разные формы слова. Поэтому существительное после
                // числа не ставится вовсе.
                notes.append(String(localized: "Сильнее всего эта коллекция делится надвое: это заметно отчётливее, чем выбранное разбиение на \(selection.k.plainDigits). Обычно так отделяются служебные обрывки (заголовки, пустые разделы) от содержательных документов. Число тем ниже — выбранная подробность, а не найденная структура: задайте своё, если нужно крупнее или мельче."))
            }
        }
        // Отмена спрашивается **внутри** счёта, а не только до и после него:
        // разбиение десяти тысяч векторов идёт секунды, и человек, нажавший
        // «Отменить», не должен смотреть на кнопку до конца арифметики.
        let fit = KMeans.fit(points, k: chosen, seed: options.seed, shouldStop: { Task.isCancelled })
        try Task.checkCancellation()

        // 4. Неотнесённые: медиана плюс два «медианных отклонения».
        //
        // Не квантиль: квантиль 0,9 объявил бы неотнесённой десятую часть любой
        // коллекции, включая идеально однородную, — то есть придумал бы находку
        // там, где её нет. Медиана и MAD на плотном разбиении не дают ни одного
        // неотнесённого, и это правильный ответ.
        let threshold = Self.outlierThreshold(fit.distances)

        var buckets: [[Int]] = Array(repeating: [], count: fit.k)
        var strays: [Int] = []
        for index in fit.assignments.indices {
            if fit.distances[index] > threshold {
                strays.append(index)
            } else {
                buckets[fit.assignments[index]].append(index)
            }
        }

        // 4а. Тексты — только у тех, кто попадёт в примеры.
        //
        // Кто это, известно ровно здесь: разбиение уже посчитано, а названия
        // ещё не спрошены. Сотня документов вместо десятков тысяч — один
        // запрос к базе вместо сотен мегабайт в памяти.
        var exampleIndexes: [Int] = []
        for bucket in buckets {
            exampleIndexes += bucket
                .sorted { fit.distances[$0] < fit.distances[$1] }
                .prefix(options.examplesPerTopic)
        }
        exampleIndexes += strays
            .sorted { fit.distances[$0] > fit.distances[$1] }
            .prefix(options.unassignedExamples)
        let excerpts = try await excerpts(of: exampleIndexes.map { ids[$0] }, in: collectionID)
        let texts = { (index: Int) in excerpts[ids[index]] ?? TopicExample.excerpt(of: nil) }

        // 5. Названия — чат-моделью, по правилам части G.
        var topics: [Topic] = []
        for cluster in 0..<fit.k {
            try Task.checkCancellation()
            let members = buckets[cluster].sorted { fit.distances[$0] < fit.distances[$1] }
            guard !members.isEmpty else { continue }
            let examples = members.prefix(options.examplesPerTopic).map {
                TopicExample(id: ids[$0], excerpt: texts($0), distance: fit.distances[$0])
            }
            var title = String(localized: "Тема \((topics.count + 1).plainDigits)")
            var summary: String?
            var named = false

            if let namer {
                progress?(Progress(
                    done: cluster + 1, total: fit.k,
                    stage: String(localized: "Названия тем: \((cluster + 1).plainDigits) из \(fit.k.plainDigits)")
                ))
                do {
                    let answer = try await namer.call(Self.prompt(for: examples.map(\.excerpt)), .topic)
                    if let parsed = Self.parse(answer) {
                        title = parsed.title
                        summary = parsed.summary
                        named = true
                    } else {
                        notes.append(String(localized: "Ответ модели на тему \((cluster + 1).plainDigits) не разобран — тема осталась без названия."))
                        log(.warning, "Темы", "Ответ модели не разобран как название темы: «\(answer.prefix(120))»")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    notes.append(String(localized: "Модель не назвала тему \((cluster + 1).plainDigits): \(error.localizedDescription)"))
                }
            }

            let distances = members.map { fit.distances[$0] }
            topics.append(Topic(
                id: cluster,
                title: title,
                summary: summary,
                isNamed: named,
                documentCount: members.count,
                share: Double(members.count) / Double(points.count),
                averageDistance: distances.reduce(0, +) / Double(distances.count),
                examples: Array(examples)
            ))
        }
        // Крупные темы сверху: список читают с начала, а вопрос, ради которого
        // его открывают, — «чего тут больше всего».
        topics.sort { ($0.documentCount, $1.title) > ($1.documentCount, $0.title) }

        let unassigned = UnassignedTopic(
            documentCount: strays.count,
            share: points.count > 0 ? Double(strays.count) / Double(points.count) : 0,
            distanceThreshold: threshold,
            examples: strays.sorted { fit.distances[$0] > fit.distances[$1] }
                .prefix(options.unassignedExamples)
                .map { TopicExample(id: ids[$0], excerpt: texts($0), distance: fit.distances[$0]) }
        )

        let report = TopicReport(
            collectionName: collection.name,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            examined: examined,
            total: max(total, examined),
            clustered: points.count,
            requestedClusters: options.clusterCount,
            seed: options.seed,
            namingModel: namer?.model,
            silhouette: fit.silhouette,
            topics: topics,
            unassigned: unassigned,
            notes: notes
        )
        log(
            .success, "Темы",
            "Коллекция «\(collection.name)»: тем \(topics.count), не отнесено \(strays.count) из \(points.count)"
        )
        return report
    }

    // MARK: - Мелочи

    /// Тексты названных документов — партиями, чтобы не собирать список из
    /// сотни идентификаторов в один запрос.
    private func excerpts(of ids: [String], in collectionID: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        var position = 0
        let unique = Array(Set(ids))
        while position < unique.count {
            try Task.checkCancellation()
            let slice = Array(unique[position..<min(position + Self.embeddingBatch, unique.count)])
            position += slice.count
            for record in try await reader.documents(collectionID: collectionID, ids: slice) {
                result[record.id] = TopicExample.excerpt(of: record.document)
            }
        }
        return result
    }

    /// Порог «не отнесён ни к одной теме»: медиана расстояний плюс два
    /// медианных абсолютных отклонения.
    ///
    /// Устойчивая к выбросам мера — в том и смысл: среднее и стандартное
    /// отклонение сами сдвигаются теми документами, которые мы пытаемся найти.
    static func outlierThreshold(_ distances: [Double]) -> Double {
        guard !distances.isEmpty else { return 1 }
        let sorted = distances.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        // Совсем плотное разбиение даёт MAD, равный нулю: порог тогда — сама
        // медиана, и неотнесённым станет половина коллекции. Такой ответ
        // бесполезен, поэтому в этом случае не отнесённых нет вовсе.
        guard mad > 0 else { return .greatestFiniteMagnitude }
        return median + 2 * mad
    }

    static func prompt(for excerpts: [String]) -> String {
        var lines = [
            "Ниже — несколько документов из одной группы одной базы знаний.",
            "Придумай короткое название темы, которая их объединяет, и одно предложение о том, что в этой группе.",
            "Название — от двух до пяти слов, без кавычек и без слова «тема».",
            "Отвечай на том языке, на котором написаны документы.",
            "Если общего между документами нет, так и напиши в описании.",
            "",
        ]
        for (index, excerpt) in excerpts.enumerated() {
            lines.append("Документ \(index + 1): \(excerpt)")
        }
        return lines.joined(separator: "\n")
    }

    /// Схема гарантирует форму ответа, но не то, что перед нами вообще JSON:
    /// модель без поддержки Structured Output ответит обычным текстом, и
    /// молчаливый провал разбора здесь недопустим — тема просто останется
    /// без названия, о чём отчёт и скажет.
    static func parse(_ answer: String) -> (title: String, summary: String?)? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = String(answer[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let title = object["title"] as? String
        else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, (summary?.isEmpty ?? true) ? nil : summary)
    }
}

public enum ClusteringError: LocalizedError, Equatable {
    case tooFewDocuments(Int)
    case tooFewVectors(Int)

    public var errorDescription: String? {
        switch self {
        case .tooFewDocuments(let count):
            return String(localized: "Документов в коллекции \(count.plainDigits) — темы выделять не из чего.")
        case .tooFewVectors(let count):
            return String(localized: "Векторов удалось прочитать \(count.plainDigits). Кластеризация берёт векторы из базы и заново их не считает, поэтому без них она невозможна.")
        }
    }
}

extension ChatJSONSchema {
    /// Что просит называние темы: название и одно предложение.
    ///
    /// Со Structured Output модель физически не может ответить абзацем
    /// рассуждений вместо названия — то же свойство, на котором стоят оценка
    /// релевантности и переранжирование.
    public static let topic = ChatJSONSchema(
        name: "topic",
        schema: [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
            ],
            "required": ["title", "summary"],
            "additionalProperties": false,
        ]
    )
}
