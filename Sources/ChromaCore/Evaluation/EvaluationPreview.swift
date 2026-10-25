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
    /// Сколько знаков помещается в карточку: пять строк колонки.
    ///
    /// Не связано с длиной фрагмента эталона (`QuerySetStore.fragmentLength`):
    /// фрагмент берётся с начала куска, чтобы пережить перенарезку, а окно
    /// показа ходит по тексту за совпадением.
    public static let limit = 240

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
    ///
    /// - Parameter rarity: насколько редко слова запроса встречаются в
    /// выдаче прогона. Без неё все слова весят одинаково.
    public static func snippet(
        of text: String, matching query: String, limit: Int = limit, rarity: Rarity? = nil
    ) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }

        let characters = Array(collapsed)
        let stems = self.stems(of: query)
        let weights = rarity?.weights(of: stems) ?? Array(repeating: 1, count: stems.count)
        let matches = self.matches(in: characters, stems: stems)
        // Ни одно слово запроса не встретилось — показывается начало, как и
        // раньше: выдумывать место, которого нет, хуже, чем показать первое.
        guard let best = bestWindow(matches: matches, weights: weights, limit: limit) else {
            return String(characters.prefix(limit)) + "…"
        }

        // Перед совпадением — немного текста, но не больше восьмой части
        // окна: ответ обычно стоит за словами вопроса («класса не ниже КС3»),
        // и с прежней четвертью он уходил за край.
        let lead = min(limit / 8, max(0, (limit - best.span) / 2))
        var start = max(0, best.start - lead)
        // Окно начинается со слова целиком: обрывок вроде «нзирование» читается
        // как опечатка.
        if start > 0 {
            while start < best.start, !characters[start - 1].isWhitespace { start += 1 }
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
            let stem = String(folded(word).prefix(stemLength))
            guard stem.count >= shortestWord else { continue }
            if !result.contains(stem) { result.append(stem) }
        }
        return result
    }

    private static func folded<S: StringProtocol>(_ word: S) -> String {
        String(word).lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Слова текста: где начинается и кончается каждое.
    private static func words(in characters: [Character]) -> [Range<Int>] {
        var result: [Range<Int>] = []
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
            result.append(start..<index)
        }
        return result
    }

    /// Где в тексте встретились слова запроса: место слова и какие из них.
    private static func matches(in characters: [Character], stems: [String]) -> [(word: Range<Int>, stems: Set<Int>)] {
        guard !stems.isEmpty else { return [] }
        var result: [(word: Range<Int>, stems: Set<Int>)] = []
        for word in words(in: characters) {
            let text = folded(String(characters[word]))
            var matched: Set<Int> = []
            for (number, stem) in stems.enumerated() where text.hasPrefix(stem) { matched.insert(number) }
            if !matched.isEmpty { result.append((word: word, stems: matched)) }
        }
        return result
    }

    /// Окно: там, где в `limit` знаков набирается больше всего веса
    /// **разных** слов запроса.
    ///
    /// Разных, а не всех подряд: кусок, где двадцать раз повторяется одно и то
    /// же слово, отвечает на запрос хуже, чем кусок, где рядом стоят три
    /// разных. Вес слова — его редкость в выдаче: «государственных
    /// информационных систем» есть почти в каждом куске прогона по ведомству, и
    /// окно, собравшее эти три слова, обходило то, где стоят «комплексное
    /// тестирование» и «дней».
    ///
    /// При равном весе — окно, где слова стоят теснее, а из равно тесных —
    /// то, что раньше: читать документ привычно сверху.
    ///
    /// - Returns: начало первого слова окна и длина от него до конца
    ///   последнего слова, добавившего новое.
    private static func bestWindow(
        matches: [(word: Range<Int>, stems: Set<Int>)], weights: [Double], limit: Int
    ) -> (start: Int, span: Int)? {
        guard !matches.isEmpty else { return nil }
        var best: (start: Int, span: Int, score: Double)?
        for (index, match) in matches.enumerated() {
            var covered = match.stems
            var span = match.word.count
            var ahead = index + 1
            while ahead < matches.count, matches[ahead].word.lowerBound < match.word.lowerBound + limit {
                if !matches[ahead].stems.isSubset(of: covered) {
                    covered.formUnion(matches[ahead].stems)
                    span = matches[ahead].word.upperBound - match.word.lowerBound
                }
                ahead += 1
            }
            let score = covered.reduce(0) { $0 + weights[$1] }
            if let current = best {
                let tie = abs(score - current.score) < 1e-9
                guard score > current.score && !tie || tie && span < current.span else { continue }
            }
            best = (match.word.lowerBound, span, score)
        }
        return best.map { ($0.start, $0.span) }
    }
}

public extension EvaluationPreview {
    /// Насколько редко каждое слово встречается в выдаче прогона.
    ///
    /// Считается по всем результатам прогона, всех запросов и вариантов, а не
    /// по выдаче одного запроса: выдача отобрана под этот вопрос, и слова
    /// вопроса в ней часты по построению. «Коэффициент» в выдаче запроса о
    /// доступности стоял в 57 кусках из 70 и весил меньше, чем «должен»;
    /// по всему прогону — в 110 из 1 476.
    struct Rarity: Sendable {
        /// В скольких текстах встретилось слово, начинающееся с основы.
        let frequency: [String: Int]
        let count: Int

        /// Считаются только основы слов из `queries`: окно ищется по ним и
        /// ни по чему больше. Все начала всех слов прогона — это словарь в
        /// сотню тысяч строк на всё время, пока прогон открыт (ревью
        ///…). Основа не из `queries` весит как не встреченная.
        public init(texts: some Sequence<String>, queries: some Sequence<String>) {
            let stems = Set(queries.flatMap { EvaluationPreview.stems(of: $0) }.map { Substring($0) })
            var frequency: [String: Int] = [:]
            var count = 0
            for text in Set(texts) where !text.isEmpty {
                count += 1
                guard !stems.isEmpty else { continue }
                var present: Set<Substring> = []
                let folded = EvaluationPreview.folded(text)
                for word in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                    // Основа бывает длиной от четырёх до шести букв.
                    for length in EvaluationPreview.shortestWord...EvaluationPreview.stemLength where word.count >= length {
                        let prefix = word.prefix(length)
                        if stems.contains(prefix) { present.insert(prefix) }
                    }
                }
                for stem in present { frequency[String(stem), default: 0] += 1 }
            }
            self.frequency = frequency
            self.count = count
        }

        /// Все тексты прогона — по основам его запросов.
        public init(run: EvaluationRun) {
            self.init(texts: run.results.lazy.flatMap(\.hits).compactMap(\.text), queries: run.queries.map(\.text))
        }

        /// Вес слова: обратная частота, как в BM25. Слово, которого в выдаче
        /// нет вовсе, весит больше всех, но и окна оно не притянет.
        func weights(of stems: [String]) -> [Double] {
            stems.map { stem in
                log((Double(count) + 1) / (Double(frequency[stem] ?? 0) + 0.5))
            }
        }
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
    static func card(for hit: EvaluationHit, query: String, rarity: Rarity? = nil) -> Card {
        let text = hit.text ?? ""
        return Card(
            shape: shape(text: hit.text, metadata: hit.metadata),
            snippet: text.isEmpty ? hit.id : snippet(of: text, matching: query, rarity: rarity)
        )
    }
}
