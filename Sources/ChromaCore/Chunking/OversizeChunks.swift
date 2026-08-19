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
            let pieces = pieces(of: chunk.text, budget: budget)
            split += 1
            for piece in pieces {
                result.append(TextChunk(
                    index: result.count, text: piece,
                    level: chunk.level, parentIndex: chunk.parentIndex, note: chunk.note
                ))
            }
        }

        // Номера проставляются заново подряд, а ссылки на родителя переводятся
        // по старым номерам: идентификатор документа собирается из номера
        // чанка, и дырка в нумерации выглядела бы как след прерванной
        // синхронизации.
        let fixed = result.enumerated().map { position, chunk -> TextChunk in
            TextChunk(
                index: position, text: chunk.text, level: chunk.level,
                parentIndex: chunk.parentIndex.flatMap { renumbered[$0] },
                note: chunk.note
            )
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
    static func pieces(of text: String, budget: Budget) -> [String] {
        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }

        for sentence in SentenceSplitter.sentences(in: text) {
            // Предложение само не влезает — режем его мельче, а накопленное
            // отдаём как есть.
            guard !doesNotFit(sentence, budget: budget) else {
                flush()
                result.append(contentsOf: split(sentence, budget: budget))
                continue
            }
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if doesNotFit(candidate, budget: budget) {
                flush()
                current = sentence
            } else {
                current = candidate
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
