import Foundation

/// How relevant a document is to a text query — computed **by the app**.
///
/// This exists because of a trap the section names explicitly. `get` with
/// `where_document: {"$contains": …}` finds documents but says nothing about
/// how well they match, and its order is not guaranteed. «Позиция в
/// текстовом списке» is therefore undefined and can change between runs — and
/// RRF is built entirely out of positions. So the app ranks them itself, by a
/// formula fixed here and covered by a test, and the order the server happened
/// to return is never used for ranking.
public enum TextRelevance {
    /// Where a term found in the heading counts as several found in the body.
    /// A chunk whose heading is the term is about the term; a chunk that
    /// mentions it eight times in passing may not be.
    public static let headingBonus = 2.0

    /// Terms of a query, as the text search will look for them.
    public static func terms(in query: String, splitIntoWords: Bool) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard splitIntoWords else { return trimmed.isEmpty ? [] : [trimmed] }
        return trimmed
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    /// Как ищется терм на сервере, где `$contains` различает регистр.
    ///
    /// Это не украшение, а условие работоспособности всей стадии: ранжирование
    /// здесь и так регистронезависимо (`occurrences`), а вот `where_document`
    /// у ChromaDB — точная подстрока. Запрос «astra linux орел» по документам
    /// со словами «Astra Linux» и «Орел» не находил **ничего**, и текстовый
    /// поиск выглядел сломанным, хотя честно спрашивал ровно то, что ему дали.
    ///
    /// Поэтому каждый терм спрашивается несколькими написаниями через `$or`.
    /// Заглавный вариант — только для коротких термов: «ASTRA LINUX ОРЕЛ» никому
    /// не нужен, а вот «IOPS», набранный как «iops», — вполне.
    ///
    /// Чего это **не** лечит: «ё» против «е» и любые другие различия внутри
    /// слова. Подстрочный поиск на стороне сервера так не умеет, и обещать это
    /// в интерфейсе нельзя.
    public static func caseVariants(of terms: [String], limit: Int = 24) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for term in terms {
            var candidates = [term, term.lowercased(), capitalisedFirst(term)]
            if term.count <= 5 { candidates.append(term.uppercased()) }
            for candidate in candidates where !candidate.isEmpty {
                if seen.insert(candidate).inserted { result.append(candidate) }
            }
        }
        return Array(result.prefix(limit))
    }

    static func capitalisedFirst(_ term: String) -> String {
        // Каждое слово с заглавной: «astra linux» → «Astra Linux». Именно так
        // пишутся названия, из-за которых стадия и не находила ничего.
        term.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// Оценка записи по уже посчитанным вхождениям.
    ///
    /// Отдельной формы «посчитай по тексту и заголовку» больше нет: она
    /// осталась без единого вызова, когда `ranked` перешёл на пакетный
    /// подсчёт, и при этом строила `DocumentRecord` со словарём метаданных
    /// на каждое обращение. Формула по-прежнему одна и покрыта тестами —
    /// через `ranked`, которым её и пользуются.
    /// - Parameter weights: вес терма по его редкости. Пусто — все
    ///   термы равны, как было до появления взвешивания.
    static func score(_ hit: Hits, terms: [String], weights: [String: Double]) -> Double {
        guard let document = hit.record.document, !document.isEmpty, !terms.isEmpty else { return 0 }
        var score = 0.0
        for term in terms {
            guard let found = hit.byTerm[term] else { continue }
            let weight = weights[term] ?? 1
            score += Double(found.occurrences) * weight
            if found.inHeading { score += headingBonus * weight }
        }
        guard score > 0 else { return 0 }
        // Divided by the square root of the length, the way Lucene normalises
        // and for the same reason: a term appearing once in a sentence says
        // more about that sentence than twice in a page. Without it the longest
        // chunk wins almost every query, purely for being long.
        return score / max(1, Double(document.count).squareRoot())
    }

    /// Вес терма по его редкости среди найденного.
    ///
    /// **Зачем.** Запрос «vCpu» находил нужное, а «ГЕОП аренда виртуальных
    /// процессоров» по тому же файлу — мусор. Разбор: слово «ГЕОП» стоит
    /// в этом документе почти на каждой странице, и без веса оно значило
    /// ровно столько же, сколько «vCPU», который встречается десяток раз.
    /// Формула складывала вхождения — и наверх выходил чанк, где чаще всего
    /// повторяется название платформы, то есть любой чанк этого документа.
    /// Одиночный редкий терм такой беды не знает: делить наверху нечего.
    ///
    /// **Как.** Обратная частота по тому набору, который вернул `$contains`:
    /// это не вся коллекция, но именно тот отбор, внутри которого мы и
    /// расставляем места. Терм, который есть у всех найденных, не отличает
    /// их друг от друга — его вес близок к нулю; терм, который есть у
    /// немногих, весит много.
    ///
    /// Запрос из одного слова не меняется вовсе: общий множитель мест
    /// не переставляет.
    public static func termWeights(
        _ terms: [String], in records: [DocumentRecord]
    ) -> [String: Double] {
        weights(terms, hits: records.map { record in
            Hits(record: record, byTerm: counts(of: terms, in: record))
        })
    }

    /// Сколько раз каждый терм встретился в записи и стоит ли он в заголовке.
    ///
    /// Считается **один раз** на запись: и вес терма, и его вклад
    /// в оценку опираются на одни и те же вхождения, а подстрочный поиск —
    /// самая дорогая часть стадии. До этого набор кандидатов обходился
    /// дважды: сперва ради частот, затем ради оценки.
    struct Hits {
        var record: DocumentRecord
        var byTerm: [String: (occurrences: Int, inHeading: Bool)]

        /// Есть ли терм в этой записи — хоть в тексте, хоть в заголовке.
        func has(_ term: String) -> Bool {
            guard let hit = byTerm[term] else { return false }
            return hit.occurrences > 0 || hit.inHeading
        }
    }

    static func counts(
        of terms: [String], in record: DocumentRecord
    ) -> [String: (occurrences: Int, inHeading: Bool)] {
        var heading: String?
        if case .string(let value)? = record.metadata?["heading_path"] { heading = value }
        var result: [String: (occurrences: Int, inHeading: Bool)] = [:]
        for term in terms where result[term] == nil {
            let found = record.document.map { occurrences(of: term, in: $0) } ?? 0
            let inHeading = heading.map {
                !$0.isEmpty && $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            } ?? false
            result[term] = (found, inHeading)
        }
        return result
    }

    /// Вес по редкости — из уже посчитанных вхождений.
    ///
    /// Заголовок учитывается наравне с текстом: вес умножает и `headingBonus`,
    /// а терм, стоящий только в пути заголовков, при подсчёте «в скольких
    /// документах он есть» иначе выглядел бы не встречающимся нигде и получал
    /// бы максимальный вес на пустом месте.
    static func weights(_ terms: [String], hits: [Hits]) -> [String: Double] {
        let total = Double(hits.count)
        guard total > 0, terms.count > 1 else { return [:] }
        var result: [String: Double] = [:]
        for term in terms where result[term] == nil {
            // Счётчиком, а не `filter{}.count`: промежуточный массив копий
            // `Hits` — со словарём и записью документа в каждой — собирался
            // бы по разу на терм запроса ровно в том пути, который эта же
            // правка избавила от второго обхода.
            var containing = 0.0
            for hit in hits where hit.has(term) { containing += 1 }
            // Классическая форма BM25: у терма, который есть у всех, вес
            // стремится к нулю, но не становится отрицательным — иначе
            // документ штрафовался бы за то, что он вообще найден.
            result[term] = max(0.05, log(1 + (total - containing + 0.5) / (containing + 0.5)))
        }
        return result
    }

    /// Case- and diacritic-insensitive, counting overlaps as one each.
    static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(
            of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange
        ) {
            count += 1
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// The text candidates, ordered by this formula.
    ///
    /// Ties break by id, so two documents that score the same come back in the
    /// same order every time. Anything scoring zero is dropped: `$contains`
    /// matched it, but if the formula cannot see the term the position it would
    /// get is meaningless.
    public static func ranked(
        _ records: [DocumentRecord], terms: [String]
    ) -> [(record: DocumentRecord, score: Double)] {
        // Вхождения считаются один раз на запись и служат обоим: и весу
        // терма по редкости, и самой оценке.
        let hits = records.map { Hits(record: $0, byTerm: counts(of: terms, in: $0)) }
        let weights = weights(terms, hits: hits)
        return hits
            .map { hit -> (record: DocumentRecord, score: Double) in
                (hit.record, score(hit, terms: terms, weights: weights))
            }
            .filter { $0.score > 0 }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.record.id < right.record.id
            }
    }
}

/// Merges several ranked lists into one.
///
/// Reciprocal Rank Fusion, because it needs no comparable scales: a cosine
/// distance and a position in a text listing cannot be added, and ranks can.
public enum ReciprocalRankFusion {
    /// The constant that flattens the curve near the top. 60 is the value the
    /// section fixes and the one the literature uses.
    public static let defaultK = 60.0

    public struct RankedList {
        public let source: CandidateSource
        /// Ids, best first.
        public let ids: [String]
        public let weight: Double

        public init(source: CandidateSource, ids: [String], weight: Double = 1) {
            self.source = source
            self.ids = ids
            self.weight = weight
        }
    }

    public struct Fused {
        public let id: String
        public let score: Double
        /// Which list contributed, and from what position (1-based) — E0.4 asks
        /// for exactly this in the diagnostics panel.
        public let placements: [(source: CandidateSource, position: Int)]

        public var sources: [CandidateSource] { placements.map(\.source) }
    }

    public static func fuse(_ lists: [RankedList], k: Double = defaultK) -> [Fused] {
        var scores: [String: Double] = [:]
        var placements: [String: [(source: CandidateSource, position: Int)]] = [:]
        // The order of first appearance, so that documents with identical
        // scores keep a stable order instead of one dictated by hashing.
        var firstSeen: [String: Int] = [:]
        var counter = 0

        for list in lists {
            for (index, id) in list.ids.enumerated() {
                let position = index + 1
                scores[id, default: 0] += list.weight / (k + Double(position))
                placements[id, default: []].append((list.source, position))
                if firstSeen[id] == nil {
                    firstSeen[id] = counter
                    counter += 1
                }
            }
        }

        return scores
            .map { Fused(id: $0.key, score: $0.value, placements: placements[$0.key] ?? []) }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return (firstSeen[left.id] ?? 0) < (firstSeen[right.id] ?? 0)
            }
    }
}
