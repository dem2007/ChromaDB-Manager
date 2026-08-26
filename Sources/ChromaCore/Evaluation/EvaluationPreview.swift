import Foundation

/// Что показать в карточке результата на стенде оценки.
///
/// Раньше карточка показывала первые 120 знаков куска — и на иерархической
/// коллекции два варианта выглядели одинаково: родитель начинается там же, где
/// его первый ребёнок, так что у трёх позиций из десяти совпадали ровно те
/// знаки, которые видел человек. Тексты при этом различались (176 позиций из
/// 180), но по карточке этого было не понять, и размечать приходилось вслепую
///.
///
/// Поэтому показывается **окрестность совпадения с запросом**, а не начало:
/// именно ради неё карточку и читают — «отвечает ли этот кусок на вопрос».
public enum EvaluationPreview {
    /// Сколько знаков помещается в карточку.
    ///
    /// Столько же, сколько уходит в эталон при отметке
    /// (`QuerySetStore.fragmentLength`), — но это совпадение, а не связь:
    /// фрагмент эталона по-прежнему берётся с начала куска, чтобы пережить
    /// перенарезку, а окно показа ходит по тексту за совпадением.
    public static let limit = 120

    /// Слова запроса длиной хотя бы столько попадают в поиск совпадения.
    ///
    /// Короткие — предлоги и союзы: «для», «как», «при» есть в любом куске,
    /// и окно вставало бы на первом попавшемся «для».
    private static let shortestWord = 4
    /// По скольким первым буквам слово считается тем же.
    ///
    /// «лицензирование» в запросе и «лицензирования» в тексте — одно слово;
    /// сравнение целиком не находило бы его вовсе. Это не морфология, а
    /// огрубление: для подсветки места в карточке его достаточно.
    private static let stemLength = 6

    /// Кусок текста вокруг совпадения с запросом — с многоточиями там, где
    /// текст обрезан.
    public static func snippet(of text: String, matching query: String, limit: Int = limit) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }

        let characters = Array(collapsed)
        let stems = self.stems(of: query)
        let matches = self.matches(in: characters, stems: stems)
        // Ни одно слово запроса не встретилось — показывается начало, как и
        // раньше: выдумывать место, которого нет, хуже, чем показать первое.
        guard let best = bestWindow(matches: matches, stems: stems.count, limit: limit) else {
            return String(characters.prefix(limit)) + "…"
        }

        var start = max(0, best - limit / 4)
        // Окно начинается со слова целиком: обрывок вроде «нзирование» читается
        // как опечатка.
        if start > 0 {
            while start < best, !characters[start - 1].isWhitespace { start += 1 }
        }
        var end = min(characters.count, start + limit)
        if end < characters.count {
            // И заканчивается словом целиком — но только если после отката
            // что-то осталось.
            var trimmed = end
            while trimmed > start, !characters[trimmed - 1].isWhitespace { trimmed -= 1 }
            if trimmed > start + limit / 2 { end = trimmed }
        }

        let body = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + body + (end < characters.count ? "…" : "")
    }

    /// Огрублённые слова запроса, по которым ищется совпадение.
    static func stems(of query: String) -> [String] {
        var result: [String] = []
        for word in query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let folded = String(word).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            guard folded.count >= shortestWord else { continue }
            let stem = String(folded.prefix(stemLength))
            if !result.contains(stem) { result.append(stem) }
        }
        return result
    }

    /// Где в тексте встретились слова запроса: начало слова и какие из них.
    private static func matches(in characters: [Character], stems: [String]) -> [(start: Int, stems: Set<Int>)] {
        guard !stems.isEmpty else { return [] }
        var result: [(start: Int, stems: Set<Int>)] = []
        var index = 0
        while index < characters.count {
            guard characters[index].isLetter || characters[index].isNumber else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, characters[index].isLetter || characters[index].isNumber {
                index += 1
            }
            let word = String(characters[start..<index]).lowercased()
                .folding(options: .diacriticInsensitive, locale: nil)
            var matched: Set<Int> = []
            for (number, stem) in stems.enumerated() where word.hasPrefix(stem) { matched.insert(number) }
            if !matched.isEmpty { result.append((start: start, stems: matched)) }
        }
        return result
    }

    /// Начало окна: там, где в `limit` знаков попадает больше всего **разных**
    /// слов запроса.
    ///
    /// Разных, а не всех подряд: кусок, где двадцать раз повторяется одно и то
    /// же слово, отвечает на запрос хуже, чем кусок, где рядом стоят три
    /// разных. При равенстве берётся то, что раньше, — читать документ
    /// привычно сверху.
    private static func bestWindow(
        matches: [(start: Int, stems: Set<Int>)], stems: Int, limit: Int
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        var best = matches[0].start
        var bestCount = 0
        for (index, match) in matches.enumerated() {
            var covered = match.stems
            var ahead = index + 1
            while ahead < matches.count, matches[ahead].start < match.start + limit {
                covered.formUnion(matches[ahead].stems)
                ahead += 1
            }
            if covered.count > bestCount {
                bestCount = covered.count
                best = match.start
                if bestCount == stems { break }
            }
        }
        return best
    }
}

public extension EvaluationPreview {
    /// Чем результат отличается от соседнего, когда начала всё же совпали:
    /// длина куска и его уровень.
    ///
    /// Родителя от ребёнка по тексту не отличить — ребёнок вырезан из начала
    /// родителя, — а на сравнении нарезок это и есть главный вопрос: «что я
    /// сейчас размечаю, раздел целиком или абзац из него».
    ///
    /// «Дочерний» — только у куска, у которого есть родитель: плоские
    /// стратегии тоже пишут `chunk_level`, и там ноль не значит «ребёнок».
    static func shape(text: String?, metadata: ChromaMetadata?) -> String? {
        let count = (text ?? "").count
        guard count > 0 else { return nil }
        var parts = [RussianCount.grouped(count, "знак", "знака", "знаков")]
        if let level = chunkLevel(metadata), level > 0 {
            parts.append(String(localized: "родительский"))
        } else if metadata?["parent_chunk_id"] != nil {
            parts.append(String(localized: "дочерний"))
        }
        return parts.joined(separator: " · ")
    }

    /// `chunk_level` пишется то числом, то строкой — в зависимости от того,
    /// через что коллекция наполнялась.
    private static func chunkLevel(_ metadata: ChromaMetadata?) -> Int? {
        switch metadata?["chunk_level"] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}

public extension EvaluationPreview {
    /// Адрес карточки: запрос, вариант и документ.
    ///
    /// Все три, как и у оценок: один вариант возвращает под одним
    /// идентификатором разный текст на разные запросы.
    struct Key: Hashable, Sendable {
        public let query: UUID
        public let variant: UUID
        public let document: String

        public init(query: UUID, variant: UUID, document: String) {
            self.query = query
            self.variant = variant
            self.document = document
        }
    }

    /// Что показано на карточке результата.
    struct Card: Equatable, Sendable {
        /// Длина куска и уровень — строка над текстом.
        public let shape: String?
        /// Окно вокруг совпадения с запросом.
        public let snippet: String

        public init(shape: String?, snippet: String) {
            self.shape = shape
            self.snippet = snippet
        }
    }

    /// Карточка одного результата.
    ///
    /// Считается по требованию — на ту строку, которую сейчас показывают
    ///: весь прогон разом стоил 513 мс при открытии, а на экране
    /// живёт три десятка строк из пятисот.
    static func card(for hit: EvaluationHit, query: String) -> Card {
        let text = hit.text ?? ""
        return Card(
            shape: shape(text: hit.text, metadata: hit.metadata),
            snippet: text.isEmpty ? hit.id : snippet(of: text, matching: query)
        )
    }
}
