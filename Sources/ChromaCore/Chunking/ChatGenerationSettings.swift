import Foundation

/// A JSON schema the model is forced to fill.
///
/// Fixed in code per task, never edited by the user: the parser on this side is
/// written against exactly this shape.
/// `@unchecked`: схема — это `[String: Any]`, каким её ждёт LM Studio. Все
/// схемы в приложении заданы литералами в коде и после создания не меняются
/// (G2: «фиксирована в коде под задачу, пользователь её не правит»), поэтому
/// делить её между задачами безопасно — но доказать это компилятору нечем.
public struct ChatJSONSchema: Hashable, @unchecked Sendable {
    public let name: String
    public let schema: [String: Any]

    public init(name: String, schema: [String: Any]) {
        self.name = name
        self.schema = schema
    }

    /// The `response_format` value LM Studio expects (confirmed live).
    public func requestValue() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": ["name": name, "strict": true, "schema": schema],
        ]
    }

    public static func == (lhs: ChatJSONSchema, rhs: ChatJSONSchema) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// Что просит оценка чат-моделью: одна градация из трёх и причина.
    ///
    /// `enum` в схеме, а не «ответь словом»: со Structured Output модель
    /// физически не может выдать градацию, которой нет в списке, — то же
    /// свойство, на котором стоит переранжирование по схеме.
    /// Причина обязательна: оценка без объяснения — оракул, которому нечего
    /// предъявить.
    public static let relevance = ChatJSONSchema(
        name: "relevance",
        schema: [
            "type": "object",
            "properties": [
                "grade": ["type": "string", "enum": ["relevant", "partial", "irrelevant"]],
                "reason": ["type": "string"],
            ],
            "required": ["grade", "reason"],
            "additionalProperties": false,
        ]
    )

    /// What LLM-based chunking asks for: a list of fragments, nothing else.
    public static let chunks = ChatJSONSchema(
        name: "chunks",
        schema: [
            "type": "object",
            "properties": ["chunks": ["type": "array", "items": ["type": "string"]]],
            "required": ["chunks"],
            "additionalProperties": false,
        ]
    )
}

/// Keys that existed before part G and are still read, so a source configured
/// earlier keeps its chunking recipe instead of quietly reverting to defaults.
enum LegacyChunkingKeys: String, CodingKey {
    case temperature
}

/// Sampling parameters for one chat-model task (part G).
///
/// One type for all four callers — LLM-based chunking, re-ranking, the
/// evaluation bench and cluster naming — because G0 forbids a
/// global «generation parameters» panel: a shared panel suggests it also
/// affects embedding, which it does not, and the user concludes that search is
/// broken after turning knobs that could never have changed it.
///
/// **Only parameters confirmed against a live LM Studio are here**.
/// `presence_penalty` is deliberately absent: it is accepted with HTTP 200 and
/// then silently ignored, and a setting that pretends to work is worse than one
/// that is missing.
public struct ChatGenerationSettings: Codable, Hashable, Sendable {
    /// none of the four tasks is creative, so the default is 0 and the UI
    /// range stops at 1.
    public var temperature: Double
    /// fixed by default. Reproducibility outweighs everything else here —
    /// re-indexing must not invent different chunk boundaries, the bench must
    /// compare variants rather than sampling noise, and a parse failure that
    /// cannot be reproduced cannot be debugged.
    public var seed: Int?
    /// the app sets this itself from the task and the input length. Left
    /// empty by default; a truncated answer is a broken answer, not a short one.
    public var maxTokens: Int?

    // G5, the collapsed «extended» block. `nil` means the field is not sent at
    // all — never a guess at what the server's own default is (same rule as the
    // HNSW parameters in A1.4).
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repeatPenalty: Double?
    public var frequencyPenalty: Double?

    public static let defaultSeed = 42

    public init(
        temperature: Double = 0,
        seed: Int? = ChatGenerationSettings.defaultSeed,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repeatPenalty: Double? = nil,
        frequencyPenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.seed = seed
        self.maxTokens = maxTokens
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.frequencyPenalty = frequencyPenalty
    }

    /// Older configurations decode with the documented defaults rather than
    /// failing, the same tolerance `AppConfiguration` has.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? ChatGenerationSettings.defaultSeed
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        topK = try c.decodeIfPresent(Int.self, forKey: .topK)
        minP = try c.decodeIfPresent(Double.self, forKey: .minP)
        repeatPenalty = try c.decodeIfPresent(Double.self, forKey: .repeatPenalty)
        frequencyPenalty = try c.decodeIfPresent(Double.self, forKey: .frequencyPenalty)
    }

    /// Request fields, omitting everything left empty.
    public func requestFields() -> [String: Any] {
        var fields: [String: Any] = ["temperature": temperature]
        if let seed { fields["seed"] = seed }
        if let maxTokens { fields["max_tokens"] = maxTokens }
        if let topP { fields["top_p"] = topP }
        if let topK { fields["top_k"] = topK }
        if let minP { fields["min_p"] = minP }
        if let repeatPenalty { fields["repeat_penalty"] = repeatPenalty }
        if let frequencyPenalty { fields["frequency_penalty"] = frequencyPenalty }
        return fields
    }

    /// Stable text for the strategy hash. Absent fields are spelled out as
    /// «-» so that «not sent» and «sent as 0» can never collide.
    public var signature: String {
        func text(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "-" }
        func text(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        return [
            "t\(String(format: "%.3f", temperature))",
            "seed:\(text(seed))",
            "max:\(text(maxTokens))",
            "tp:\(text(topP))",
            "tk:\(text(topK))",
            "mp:\(text(minP))",
            "rp:\(text(repeatPenalty))",
            "fp:\(text(frequencyPenalty))",
        ].joined(separator: ",")
    }

    /// Whether anything in the extended block is set — drives the «расширенные»
    /// disclosure being open on load.
    public var usesExtendedBlockValues: Bool {
        topP != nil || topK != nil || minP != nil || repeatPenalty != nil || frequencyPenalty != nil
    }
}

/// What a model picker offers when the list of models is not loaded yet.
public enum ModelPickerOptions {
    /// The list of chat models is filled only after «Проверить соединение», but a
    /// source configured earlier already names one. Without it in the list the
    /// picker draws itself empty — while the Structured Output indicator right
    /// under it reports on that very model. Rule 2 of Приложение 5 forbids that:
    /// nothing changes on its own, and nothing may look changed when it is not.
    public static func merging(configured: String?, into available: [String]) -> [String] {
        guard let configured, !configured.isEmpty, !available.contains(configured) else {
            return available
        }
        return [configured] + available
    }
}
