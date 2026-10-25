import Foundation

/// Чанк, не влезающий в контекст модели, дорезается по предложениям.
///
/// **Что было.** Один такой чанк отменял индексацию **всего файла**: правило
/// 3 предпочитает пропустить документ, чем записать его с молча обрезанным
/// хвостом. Живой случай: файл на 60 страниц не попал в базу из-за
/// пятнадцатого чанка в 2036 токенов при контексте модели 2048.
///
/// Правило про обрезанный хвост остаётся в силе — просто хвост больше некуда
/// девать: он становится следующим чанком. Молчания при этом нет, число
/// дорезанных чанков называется в сводке прогона.
///
/// Почему по предложениям: граница предложения — самое дешёвое место разреза,
/// на котором смысл кусков остаётся читаемым. Предложение, которое само
/// длиннее контекста (строка таблицы, сплошной список), режется по словам,
/// а слово длиннее контекста — по знакам: такого не бывает у текста, но
/// бывает у выгрузок, и падать на них нельзя.
public enum OversizeChunks {
    /// Какую долю контекста занимать после дорезки.
    ///
    /// Не весь: оценка токенов приблизительная, и кусок, влезающий
    /// впритык, — это тот же промах, только позже.
    public static let targetShare = 0.85

    /// Чанки, каждый из которых влезает в контекст модели.
    ///
    /// Возвращает и число дорезанных: человек должен узнать, что нарезка
    /// подвинулась, — обычно это значит, что размер чанка стоит уменьшить.
    /// `characterLimit` — сколько знаков модель читает **на самом деле**
    ///. Мерится пробой и с контекстом в токенах не совпадает:
    /// живой случай — контекст 8192 токена и предел 2937 знаков. Чанк
    /// в 7159 знаков проходил проверку по токенам, а до модели доезжала
    /// треть его; файл целиком уходил в пропущенные.
    public static func fitted(
        _ chunks: [TextChunk], contextLength: Int?, characterLimit: Int? = nil
    ) -> (chunks: [TextChunk], split: Int) {
        let limit = (contextLength ?? 0) > 0 ? contextLength : nil
        let characters = (characterLimit ?? 0) > 0 ? characterLimit : nil
        guard limit != nil || characters != nil else { return (chunks, 0) }
        guard chunks.contains(where: { doesNotFit($0.text, limit: limit, characters: characters) })
        else { return (chunks, 0) }

        let budget = Budget(
            tokens: limit.map { max(1, Int(Double($0) * targetShare)) },
            characters: characters.map { max(1, Int(Double($0) * targetShare)) }
        )
        var result: [TextChunk] = []
        var split = 0
        /// Старый номер чанка → новый номер его первого куска. Нужен ссылкам
        /// иерархической нарезки: `parentIndex` указывает на номер, а номера
        /// после дорезки сдвигаются.
        var renumbered: [Int: Int] = [:]

        for chunk in chunks {
            renumbered[chunk.index] = result.count
            guard doesNotFit(chunk.text, limit: limit, characters: characters) else {
                result.append(chunk)
                continue
            }
            split += 1
            for piece in pieces(of: chunk, budget: budget) {
                result.append(piece.renumbered(result.count, parentIndex: piece.parentIndex))
            }
        }

        // Номера проставляются заново подряд, а ссылки на родителя переводятся
        // по старым номерам: идентификатор документа собирается из номера
        // чанка, и дырка в нумерации выглядела бы как след прерванной
        // синхронизации.
        let fixed = result.enumerated().map { position, chunk -> TextChunk in
            chunk.renumbered(position, parentIndex: chunk.parentIndex.flatMap { renumbered[$0] })
        }
        return (fixed, split)
    }

    /// Во что кусок обязан уложиться: в токены модели, в знаки, которые она
    /// читает на самом деле, или в то и другое разом.
    struct Budget {
        let tokens: Int?
        let characters: Int?
    }

    static func doesNotFit(_ text: String, limit: Int?, characters: Int?) -> Bool {
        if let characters, text.count > characters { return true }
        guard let limit else { return false }
        if case .tooLong = ContextBudget.check(text, contextLength: limit) { return true }
        return false
    }

    static func doesNotFit(_ text: String, limit: Int) -> Bool {
        doesNotFit(text, limit: limit, characters: nil)
    }

    static func doesNotFit(_ text: String, budget: Budget) -> Bool {
        doesNotFit(text, limit: budget.tokens, characters: budget.characters)
    }

    /// Куски текста, каждый в пределах бюджета.
    ///
    /// Таблица делится по строкам, и каждая часть получает шапку:
    /// раньше кусок таблицы дорезался по «предложениям» и склеивался
    /// пробелом — строки сливались в одну, «2.4 ГГц» становилось «2. 4 ГГц»,
    /// а вторая и дальше части оставались без шапки.
    ///
    /// Части таблицы несут длину дописанной шапки: по ней `get_file`
    /// снимает шапку на стыке. Часть, которую пришлось дорезать ещё и по
    /// предложениям, её теряет — шапка там только у первого обрывка.
    static func pieces(of chunk: TextChunk, budget: Budget) -> [TextChunk] {
        func plain(_ text: String) -> TextChunk {
            TextChunk(index: chunk.index, text: text, level: chunk.level, parentIndex: chunk.parentIndex, note: chunk.note)
        }
        if TableChunks.containsTable(chunk.text) {
            let parts = TableChunks.headedPieces(
                of: chunk, limit: characters(in: budget), headers: TableChunkHeaders.headers(in: chunk.text)
            )
            if parts.count > 1 {
                return parts.flatMap { part -> [TextChunk] in
                    guard doesNotFit(part.text, budget: budget) else { return [part] }
                    return sentencePieces(of: part.text, budget: budget).enumerated().map { position, text in
                        var piece = plain(text)
                        if position == 0, text.hasPrefix(part.text.prefix(part.repeatedHeaderLength)) {
                            piece.repeatedHeaderLength = part.repeatedHeaderLength
                        }
                        return piece
                    }
                }
            }
        }
        return sentencePieces(of: chunk.text, budget: budget).map(plain)
    }

    /// Бюджет в знаках: замеренный предел или токены по пессимистичной
    /// оценке — меньшее из двух.
    static func characters(in budget: Budget) -> Int {
        let byTokens = budget.tokens.map { max(1, Int(Double($0) * TokenEstimator.pessimisticCharactersPerToken)) }
        return [byTokens, budget.characters].compactMap { $0 }.min() ?? Int.max
    }

    /// Проза — по предложениям, **вырезкой** из текста: переводы строк
    /// между предложениями остаются, как стояли.
    static func sentencePieces(of text: String, budget: Budget) -> [String] {
        var result: [String] = []
        var span: Range<String.Index>?

        func flush() {
            if let span {
                let piece = text[span].trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { result.append(piece) }
            }
            span = nil
        }

        for range in SentenceSplitter.ranges(in: text) {
            // Предложение само не влезает — режем его мельче, а накопленное
            // отдаём как есть.
            guard !doesNotFit(String(text[range]), budget: budget) else {
                flush()
                result.append(contentsOf: split(String(text[range]), budget: budget))
                continue
            }
            guard let current = span else {
                span = range
                continue
            }
            let candidate = current.lowerBound..<range.upperBound
            if doesNotFit(String(text[candidate]), budget: budget) {
                flush()
                span = range
            } else {
                span = candidate
            }
        }
        flush()
        return result.isEmpty ? [text] : result
    }

    /// Крайний случай: кусок без границ предложений. Режется по словам,
    /// а слово, которое само не влезает, — по знакам.
    private static func split(_ text: String, budget: Budget) -> [String] {
        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if doesNotFit(candidate, budget: budget) {
                if !current.isEmpty { result.append(current) }
                current = doesNotFit(word, budget: budget) ? "" : word
                if doesNotFit(word, budget: budget) {
                    result.append(contentsOf: chopped(word, budget: budget))
                }
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }

    /// Совсем крайний случай: одно «слово» длиннее контекста. Такого не бывает
    /// у текста, но бывает у выгрузок в одну строку.
    private static func chopped(_ word: String, budget: Budget) -> [String] {
        // По знакам, с пессимистичной оценкой: сколько знаков приходится
        // на токен, зависит от письма, и брать среднее здесь нельзя.
        // Замеренный предел в знаках, если он есть, точнее любой оценки.
        let byTokens = budget.tokens.map { max(1, Int(Double($0) * TokenEstimator.pessimisticCharactersPerToken)) }
        let perPiece = [byTokens, budget.characters].compactMap { $0 }.min() ?? 1
        var result: [String] = []
        var start = word.startIndex
        while start < word.endIndex {
            let end = word.index(start, offsetBy: perPiece, limitedBy: word.endIndex) ?? word.endIndex
            result.append(String(word[start..<end]))
            start = end
        }
        return result
    }
}
