import Foundation

/// How relevant a result is to a query.
///
/// Three grades and not two: «частично» is the honest answer for a chunk that
/// touches the subject without answering the question, and forcing it into
/// «да» or «нет» is what makes hand-marking produce numbers nobody believes.
public enum RelevanceGrade: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    case relevant
    case partial
    case irrelevant

    public var title: String {
        switch self {
        case .relevant: return String(localized: "релевантен")
        case .partial: return String(localized: "частично")
        case .irrelevant: return String(localized: "нерелевантен")
        }
    }

    /// The gain this grade contributes to nDCG.
    ///
    /// «Частично» is half a hit rather than a whole one or none: a metric that
    /// rounded it either way would move with the marking rather than with the
    /// search. Recall does not use the gain — it counts whether the passage was
    /// retrieved at all (`isHit`), because «нашлось наполовину» is not a thing
    /// that happens to a document.
    public var gain: Double {
        switch self {
        case .relevant: return 1
        case .partial: return 0.5
        case .irrelevant: return 0
        }
    }

    /// Whether a result of this grade counts as a hit at all.
    public var isHit: Bool { self != .irrelevant }
}

/// A fragment of text that a relevant document is expected to contain.
///
/// **The primary form of ground truth, and deliberately not a document id.**
/// Chunk ids depend on the chunking strategy, so an id-based reference stops
/// meaning anything the moment a variant is cut differently — which is exactly
/// the comparison this stage exists for. A fragment of the text survives
/// re-chunking, re-embedding and a change of model.
public struct ExpectedFragment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The substring itself, as the user marked it.
    public var fragment: String
    public var grade: RelevanceGrade
    /// Where it came from: the run that produced it, for «откуда это взялось».
    public var note: String

    // Самое ценное в файле — здесь: это и есть ручная разметка.
    // Недостающая заметка не повод потерять оценку, которую человек поставил.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fragment = try container.decode(String.self, forKey: .fragment)
        grade = try container.decodeIfPresent(RelevanceGrade.self, forKey: .grade) ?? .relevant
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    public init(
        id: UUID = UUID(),
        fragment: String,
        grade: RelevanceGrade = .relevant,
        note: String = ""
    ) {
        self.id = id
        self.fragment = fragment
        self.grade = grade
        self.note = note
    }

    /// The form both sides of a comparison are reduced to.
    ///
    /// Whitespace is collapsed and case ignored: re-chunking rewraps lines, and
    /// a fragment that stopped matching because a newline moved would quietly
    /// turn a hit into a miss — the failure mode this whole design avoids.
    public static func normalised(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Whether a document's text satisfies this expectation.
    public func matches(_ document: String?) -> Bool {
        guard let document else { return false }
        return matches(normalisedDocument: Self.normalised(document))
    }

    /// То же по уже приведённому тексту документа.
    ///
    /// Приведение документа — самая дорогая часть сравнения: разбиение по
    /// словам, склейка, регистр и диакритика на куске в тысячи символов.
    /// Делать его на **каждый** фрагмент эталона, как раньше, значит повторять
    /// одну и ту же работу столько раз, сколько отметок у запроса. На живых
    /// данных (200 результатов, 654 000 символов, 11 фрагментов) это
    /// превращало пересчёт метрик в 873 мс.
    public func matches(normalisedDocument: String) -> Bool {
        guard !fragment.isEmpty else { return false }
        return normalisedDocument.contains(Self.normalised(fragment))
    }
}

/// A document named by id, with a grade (the secondary form).
///
/// Kept because it is precise where it applies — the same collection, unchanged
/// — and useless where it does not: ids are not comparable between variants cut
/// by different strategies. The interface says so where they are entered.
public struct ExpectedDocument: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var grade: RelevanceGrade

    public init(id: String, grade: RelevanceGrade = .relevant) {
        self.id = id
        self.grade = grade
    }
}

/// One query of a set.
public struct EvaluationQuery: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    /// Applied together with the query, as on the search screen.
    public var filter: DocumentFilter?
    public var tags: [String]
    public var comment: String
    /// Ground truth by text — the form that survives a change of strategy.
    public var fragments: [ExpectedFragment]
    /// Ground truth by id — exact, and only within one collection.
    public var documents: [ExpectedDocument]

    public init(
        id: UUID = UUID(),
        text: String,
        filter: DocumentFilter? = nil,
        tags: [String] = [],
        comment: String = "",
        fragments: [ExpectedFragment] = [],
        documents: [ExpectedDocument] = []
    ) {
        self.id = id
        self.text = text
        self.filter = filter
        self.tags = tags
        self.comment = comment
        self.fragments = fragments
        self.documents = documents
    }

    // Разбор терпим к недостающим полям — по той же причине, что у профиля
    // поиска. Здесь она даже весомее: в наборе живёт эталон, то есть
    // ручная разметка человека, и одно поле, которого не оказалось в файле,
    // роняло разбор **всего файла** — со всеми наборами и всей разметкой
    // разом. Живой случай: набор, записанный без `tags` и `comment`, дал
    // «Не удалось прочитать данные, так как они отсутствуют», и экран остался
    // без единого набора.
    //
    // `id` и `text` обязательны и умолчания не имеют: запрос без текста —
    // это не запрос, и подставлять ему пустую строку значило бы прятать
    // испорченный файл вместо того, чтобы о нём сказать.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        filter = try container.decodeIfPresent(DocumentFilter.self, forKey: .filter)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        fragments = try container.decodeIfPresent([ExpectedFragment].self, forKey: .fragments) ?? []
        documents = try container.decodeIfPresent([ExpectedDocument].self, forKey: .documents) ?? []
    }

    /// Whether anything is known about what a good answer looks like.
    ///
    /// Metrics are computed only where this is true — a query with no
    /// ground truth still runs and is still shown, it simply has nothing to be
    /// scored against.
    public var hasGroundTruth: Bool { !fragments.isEmpty || !documents.isEmpty }

    /// How relevant a result is, according to what has been marked.
    ///
    /// Fragments are consulted before ids: the fragment is the portable form,
    /// and where both speak the portable one is the one that stays true across
    /// variants. `nil` means «не размечено» — distinct from «нерелевантен»,
    /// because an unmarked result is not evidence of anything.
    public func grade(forDocument id: String, text: String?) -> RelevanceGrade? {
        // Текст приводится **один раз** на весь список фрагментов, а не на
        // каждый: приведение — самая дорогая часть сравнения.
        let normalised = text.map { ExpectedFragment.normalised($0) }
        // The strongest statement among matching fragments wins: a chunk that
        // contains both a «релевантен» fragment and a «частично» one is at
        // least partially the answer.
        let matched = fragments.filter { fragment in
            guard let normalised else { return false }
            return fragment.matches(normalisedDocument: normalised)
        }
        if let best = matched.map(\.grade).min(by: { $0.gain > $1.gain }) {
            // `min` by descending gain — the highest grade present.
            return best
        }
        return documents.first { $0.id == id }?.grade
    }

    /// How many documents are known to be relevant at all — what `recall`
    /// divides by, and `nil` when the list cannot be treated as complete.
    ///
    /// Only ids give a complete list: fragments say «этот текст должен быть
    /// найден», never «и больше ничего». Dividing by a count of fragments would
    /// invent a denominator and report a recall that means nothing.
    public var knownRelevantCount: Int? {
        guard !documents.isEmpty else { return nil }
        return documents.filter { $0.grade.isHit }.count
    }
}

/// A named list of queries, attached to a task rather than to a collection
///.
///
/// Not to a collection on purpose: the point of the stage is running one set
/// against several variants, and a set that belonged to a collection could not
/// be run against its clone.
public struct QuerySet: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var note: String
    public var queries: [EvaluationQuery]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        queries: [EvaluationQuery] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.queries = queries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Те же соображения, что у запроса. Даты по умолчанию — «сейчас»:
    // набор без них существует, а неверная дата ничего не решает, тогда как
    // отказ читать файл стоит человеку всей разметки.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        queries = try container.decodeIfPresent([EvaluationQuery].self, forKey: .queries) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public var markedQueryCount: Int { queries.filter(\.hasGroundTruth).count }

    public var line: String {
        let queries = RussianCount.phrase(self.queries.count, "запрос", "запроса", "запросов")
        return String(localized: "\(queries), с эталоном \(markedQueryCount)")
    }
}
