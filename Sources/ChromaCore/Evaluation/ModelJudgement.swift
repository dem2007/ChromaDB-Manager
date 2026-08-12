import Foundation

/// Оценка релевантности, выставленная чат-моделью.
///
/// **Почему отдельный тип, а не `RelevanceGrade` в наборе запросов.** ТЗ
/// требует хранить это отдельно от ручной разметки и никогда её не
/// перезаписывать. Разделение проведено на уровне типа, а не соглашения:
/// оценка модели физически не может попасть в `QuerySet`, потому что не
/// является ни `ExpectedFragment`, ни `ExpectedDocument`. Соглашение
/// «мы туда не пишем» продержалось бы до первого удобного случая.
public struct ModelJudgement: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// К какому результату относится: прогон + запрос + документ.
    public var queryID: UUID
    public var variantID: UUID
    public var documentID: String
    public var grade: RelevanceGrade
    /// Почему модель так решила — её собственными словами.
    ///
    /// Не украшение: без объяснения оценка модели становится оракулом,
    /// которому нечего предъявить. С объяснением человек видит, поняла ли
    /// модель вопрос, и решает сам — а решать должен он (D1.5: «оценка модели
    /// не является истиной»).
    public var reason: String
    public var model: String
    /// Каким промптом получена. Промпт редактируемый, и оценка, снятая старой
    /// редакцией, не сравнима с новой — знать об этом надо не догадкой.
    public var promptFingerprint: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        queryID: UUID,
        variantID: UUID,
        documentID: String,
        grade: RelevanceGrade,
        reason: String,
        model: String,
        promptFingerprint: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.queryID = queryID
        self.variantID = variantID
        self.documentID = documentID
        self.grade = grade
        self.reason = reason
        self.model = model
        self.promptFingerprint = promptFingerprint
        self.createdAt = createdAt
    }
}

/// Оценки модели по одному прогону.
public struct JudgementSet: Codable, Hashable, Sendable {
    public var runID: UUID
    public var judgements: [ModelJudgement]
    /// Прогон оценки не доведён до конца — отменён или были сбои.
    public var isComplete: Bool
    public var note: String

    public init(
        runID: UUID,
        judgements: [ModelJudgement] = [],
        isComplete: Bool = false,
        note: String = ""
    ) {
        self.runID = runID
        self.judgements = judgements
        self.isComplete = isComplete
        self.note = note
    }

    public func judgement(query: UUID, variant: UUID, document: String) -> ModelJudgement? {
        judgements.first {
            $0.queryID == query && $0.variantID == variant && $0.documentID == document
        }
    }

    /// Сколько оценок каждой градации — строка под таблицей.
    public var line: String {
        let relevant = judgements.filter { $0.grade == .relevant }.count
        let partial = judgements.filter { $0.grade == .partial }.count
        let irrelevant = judgements.filter { $0.grade == .irrelevant }.count
        var parts = [
            String(localized: "оценок модели: \(judgements.count)"),
            String(localized: "релевантных \(relevant), частично \(partial), нет \(irrelevant)"),
        ]
        if !isComplete { parts.append(String(localized: "оценка неполная")) }
        return parts.joined(separator: " · ")
    }
}

/// Промпт оценки — фиксированный по смыслу, редактируемый по тексту.
public struct JudgePrompt: Codable, Hashable, Sendable {
    /// Что подставляется. Схема ответа при этом **не** редактируется: парсер
    /// на этой стороне написан ровно под неё, и «редактируемая схема»
    /// означала бы редактируемый разбор ответа.
    public static let queryPlaceholder = "{query}"
    public static let documentPlaceholder = "{document}"

    public var text: String

    public init(text: String = JudgePrompt.defaultText) {
        self.text = text
    }

    public static let defaultText = """
        Оцени, отвечает ли фрагмент документа на запрос.

        Запрос: {query}

        Фрагмент:
        {document}

        Ответь одним из: relevant — фрагмент отвечает на запрос; partial — \
        касается темы, но не отвечает; irrelevant — не относится к запросу. \
        Кратко объясни почему.
        """

    /// Чего не хватает, чтобы промпт вообще мог работать.
    ///
    /// Проверяется до запуска, а не после первого пустого ответа: прогон
    /// оценки — это вызов модели на каждый результат, и узнавать о том, что
    /// в промпте нет запроса, через десять минут — дорого.
    public var problem: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Промпт пуст.")
        }
        var missing: [String] = []
        if !text.contains(Self.queryPlaceholder) { missing.append(Self.queryPlaceholder) }
        if !text.contains(Self.documentPlaceholder) { missing.append(Self.documentPlaceholder) }
        guard missing.isEmpty else {
            return String(localized: "В промпте нет подстановок: \(missing.joined(separator: ", ")). Без них модель увидит один и тот же текст на каждом результате.")
        }
        return nil
    }

    public func filled(query: String, document: String) -> String {
        text
            .replacingOccurrences(of: Self.queryPlaceholder, with: query)
            .replacingOccurrences(of: Self.documentPlaceholder, with: document)
    }

    /// Короткая подпись редакции промпта — чтобы оценка помнила, чем получена.
    public var fingerprint: String {
        let normalised = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(format: "%08x", UInt32(truncatingIfNeeded: normalised.hashValue))
    }

    public var isDefault: Bool {
        JudgePrompt(text: text).fingerprint == JudgePrompt().fingerprint
    }
}

/// Что будет стоить прогон оценки (D1.5 — предупреждение обязательно).
public struct JudgementCost: Hashable, Sendable {
    /// Вызовов чат-модели — по одному на каждый результат каждого варианта.
    public let calls: Int
    /// Сколько из них уже оценено этой же редакцией промпта и не будет
    /// повторено.
    public let alreadyJudged: Int
    /// Оценка времени, или `nil`, когда скорость этой модели ещё не измерена.
    /// Никогда не догадка (12.7).
    public let seconds: Double?

    public init(calls: Int, alreadyJudged: Int, seconds: Double?) {
        self.calls = calls
        self.alreadyJudged = alreadyJudged
        self.seconds = seconds
    }

    public static func estimate(
        run: EvaluationRun,
        existing: JudgementSet?,
        promptFingerprint: String,
        secondsPerCall: Double?
    ) -> JudgementCost {
        var total = 0
        var done = 0
        for result in run.results where result.succeeded {
            for hit in result.hits {
                total += 1
                if let judged = existing?.judgement(
                    query: result.queryID, variant: result.variantID, document: hit.id
                ), judged.promptFingerprint == promptFingerprint {
                    done += 1
                }
            }
        }
        let remaining = max(0, total - done)
        return JudgementCost(
            calls: remaining,
            alreadyJudged: done,
            seconds: secondsPerCall.map { $0 * Double(remaining) }
        )
    }

    public var durationText: String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 90 { return String(localized: "около \(Int(seconds.rounded())) с") }
        if seconds < 5_400 { return String(localized: "около \(Int((seconds / 60).rounded())) мин") }
        return String(localized: "около \(String(format: "%.1f", seconds / 3_600)) ч")
    }

    /// Строка перед стартом. Число вызовов — всегда; время — только если
    /// измерено.
    public var line: String {
        var parts = [RussianCount.phrase(calls, "вызов чат-модели", "вызова чат-модели", "вызовов чат-модели")]
        if alreadyJudged > 0 {
            parts.append(String(localized: "уже оценено тем же промптом: \(alreadyJudged)"))
        }
        if let durationText {
            parts.append(String(localized: "\(durationText) — по фактической скорости этой модели"))
        } else if calls > 0 {
            parts.append(String(localized: "время неизвестно: скорость этой модели ещё не измерена"))
        }
        return parts.joined(separator: " · ")
    }

    /// Выше этого прогон длинный настолько, что запускать его случайно —
    /// заметная потеря.
    public static let warningThreshold = 40

    public var isLong: Bool { calls > Self.warningThreshold || (seconds ?? 0) > 300 }
}
