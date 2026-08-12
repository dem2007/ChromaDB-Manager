import Foundation

/// Measured averages, accumulated from real runs.
///
/// The statistics screen must show how long embedding and chunking actually take
/// — especially for LLM-based, which is far slower than the rest and where that
/// has to be visible **before** someone points it at a big folder. Guessed
/// numbers would defeat the purpose, so these come from the runs themselves.
public struct MetricsSnapshot: Codable, Hashable {
    public struct ModelMetric: Codable, Hashable, Identifiable {
        public var model: String
        public var texts: Int
        public var seconds: Double

        public var id: String { model }
        /// Seconds per text — the number worth comparing between models.
        public var averageSeconds: Double { texts > 0 ? seconds / Double(texts) : 0 }
    }

    public struct StrategyMetric: Codable, Hashable, Identifiable {
        public var strategy: ChunkStrategy
        public var runs: Int
        public var characters: Int
        public var seconds: Double

        public var id: String { strategy.rawValue }
        public var averageSeconds: Double { runs > 0 ? seconds / Double(runs) : 0 }
        /// Thousands of characters per second, which is comparable across files.
        public var throughput: Double { seconds > 0 ? Double(characters) / seconds / 1000 : 0 }
    }

    public var models: [ModelMetric]
    public var strategies: [StrategyMetric]
    /// Скорость чат-модели на оценке релевантности, в отдельном списке.
    ///
    /// Не в `models`: там скорость **эмбеддинга**, и подмешать туда чат-вызов
    /// значило бы испортить оценку стоимости прогона стенда, которая читает
    /// именно эти числа. Одно имя модели, две разные работы.
    public var judges: [ModelMetric]

    public init(
        models: [ModelMetric] = [],
        strategies: [StrategyMetric] = [],
        judges: [ModelMetric] = []
    ) {
        self.models = models
        self.strategies = strategies
        self.judges = judges
    }

    public var isEmpty: Bool { models.isEmpty && strategies.isEmpty && judges.isEmpty }

    /// Читается так, чтобы файл, записанный **прежней** сборкой, оставался
    /// читаемым.
    ///
    /// Синтезированный декодер требует каждое поле. Поэтому `judges`,
    /// добавленный вместе с D1.5, сделал нечитаемым весь накопленный
    /// `metrics.json`: приложение честно отказалось его перезаписывать —
    /// и статистика перестала копиться вовсе, а в каталоге начали
    /// накапливаться спасённые копии, по одной на запуск.
    ///
    /// Отсутствующий раздел — это «ещё ничего не измерено», а не «файл
    /// испорчен». То же правило уже действует для настроек приложения; здесь
    /// оно просто забыто, и теперь закреплено тестом.
    /// Терпимость к **отсутствующему разделу** — но не к чужому файлу.
    ///
    /// Если разрешить вообще всё, любой посторонний JSON прочитается как
    /// пустая статистика, а потом будет ею перезаписан — то есть накопленное
    /// за недели измерение тихо исчезнет. Поэтому хотя бы один известный
    /// раздел обязан быть: своё приложение всегда пишет все три.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let models = try container.decodeIfPresent([ModelMetric].self, forKey: .models)
        let strategies = try container.decodeIfPresent([StrategyMetric].self, forKey: .strategies)
        let judges = try container.decodeIfPresent([ModelMetric].self, forKey: .judges)
        guard models != nil || strategies != nil || judges != nil else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "это не файл статистики: нет ни одного известного раздела"
            ))
        }
        self.models = models ?? []
        self.strategies = strategies ?? []
        self.judges = judges ?? []
    }

    /// Секунды на один вызов оценки, или `nil`, если эта модель ещё не
    /// работала: оценка времени берётся из измерения или не берётся вовсе.
    public func judgeSecondsPerCall(model: String) -> Double? {
        guard let metric = judges.first(where: { $0.model == model }), metric.averageSeconds > 0 else {
            return nil
        }
        return metric.averageSeconds
    }
}

/// Accumulates timings and keeps them in
/// `~/Library/Application Support/ChromaDBManager/metrics.json`.
public actor MetricsStore {
    private let file: GuardedJSONFile<MetricsSnapshot>
    private let log: LogHandler
    private var snapshot: MetricsSnapshot
    private var saveTask: Task<Void, Never>?

    public init(fileURL: URL = AppPaths.metricsFile, log: @escaping LogHandler = noopLogHandler) {
        // Даты здесь не пишутся вовсе, поэтому кодировщики простые — менять их
        // значило бы сделать нечитаемым уже накопленное.
        self.file = GuardedJSONFile(
            url: fileURL,
            category: "Статистика",
            log: log,
            decoder: { JSONDecoder() },
            encoder: {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return encoder
            }
        )
        self.log = log
        self.snapshot = file.value(or: MetricsSnapshot())
    }

    /// Почему ничего не сохраняется, если это так.
    public func persistenceProblem() -> String? { file.problem }

    public func current() -> MetricsSnapshot { snapshot }

    public func recordEmbedding(model: String, texts: Int, duration: TimeInterval) {
        guard texts > 0, duration >= 0 else { return }
        if let index = snapshot.models.firstIndex(where: { $0.model == model }) {
            snapshot.models[index].texts += texts
            snapshot.models[index].seconds += duration
        } else {
            snapshot.models.append(MetricsSnapshot.ModelMetric(model: model, texts: texts, seconds: duration))
        }
        scheduleSave()
    }

    /// сколько времени модель тратит на одну оценку. Отсюда берётся
    /// «около N мин» перед следующим прогоном — и только отсюда.
    public func recordJudgement(model: String, calls: Int, duration: TimeInterval) {
        guard calls > 0, duration >= 0 else { return }
        if let index = snapshot.judges.firstIndex(where: { $0.model == model }) {
            snapshot.judges[index].texts += calls
            snapshot.judges[index].seconds += duration
        } else {
            snapshot.judges.append(MetricsSnapshot.ModelMetric(model: model, texts: calls, seconds: duration))
        }
        scheduleSave()
    }

    public func recordChunking(strategy: ChunkStrategy, characters: Int, duration: TimeInterval) {
        guard characters > 0, duration >= 0 else { return }
        if let index = snapshot.strategies.firstIndex(where: { $0.strategy == strategy }) {
            snapshot.strategies[index].runs += 1
            snapshot.strategies[index].characters += characters
            snapshot.strategies[index].seconds += duration
        } else {
            snapshot.strategies.append(MetricsSnapshot.StrategyMetric(
                strategy: strategy, runs: 1, characters: characters, seconds: duration
            ))
        }
        scheduleSave()
    }

    public func reset() {
        snapshot = MetricsSnapshot()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let stored = snapshot
        saveTask = Task { [file] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            file.write(stored)
        }
    }
}
