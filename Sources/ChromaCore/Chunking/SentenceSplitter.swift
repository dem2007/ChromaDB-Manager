import Foundation

/// Предложения текста — границами в самом тексте.
///
/// **Что было.** Граница ставилась после любой точки, `!`, `?` и перевода
/// строки, а предложения потом склеивались пробелом. «1 234 567.00 руб.
/// см. п. 1.2 договора» распадалось на шесть «предложений»: `1 234 567.`,
/// `00 руб.`, `см.`, `п.`, `1.`, `2 договора.` — семантическая нарезка
/// мерила смысл обрывков, а дорезка длинных кусков ставила границу внутри
/// числа. Склейка пробелом стирала переводы строк: таблица становилась одной
/// строкой, «2.4 ГГц» — «2. 4 ГГц».
///
/// **Как теперь.**
/// - Перевод строки — граница всегда: строка таблицы, пункт списка,
///   абзац сшитого PDF — каждый своё.
/// - Строка таблицы (`| … |`) — одно предложение целиком, какие бы точки
///   в ней ни стояли.
/// - Точка, `!`, `?`, `…` — граница, только если за ними пробел и начало
///   нового предложения: прописная буква, цифра, кавычка или скобка.
///   Точка внутри числа («1.2», «838.00») границей не бывает — за ней
///   нет пробела.
/// - Не граница: сокращение («см.», «п.», «г.», «руб.», «т. е.»), инициал
///   («А. С. Пушкин»), номер пункта в начале строки («1. Предмет»).
///
/// Отдаются **диапазоны**: кусок собирается вырезкой из исходного текста
/// от начала первого предложения до конца последнего, и всё, что стояло
/// между ними, — переводы строк, отступы — остаётся как было.
public enum SentenceSplitter {
    /// Предложения без краевых пробелов — для эмбеддинга и подсчёта.
    public static func sentences(in text: String) -> [String] {
        ranges(in: text).map { String(text[$0]) }
    }

    /// Диапазоны предложений в `text`, без краевых пробелов, по порядку.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            // Любой перевод строки: в Swift «\r\n» — один знак, и поиск
            // «\n» его не видел, — текст из Windows шёл одной строкой.
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            result += ranges(inLine: text, lineStart..<lineEnd)
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return result
    }

    /// Сокращения, после которых точка не кончает предложение. Строчными,
    /// без точки. Сличается одно слово перед точкой — до пробела, — так что
    /// «в т.ч.» здесь пишется как «т.ч».
    static let abbreviations: Set<String> = [
        "г", "гг", "см", "ср", "п", "пп", "пл", "ст", "ч", "чч", "т", "тт", "д", "др", "пр", "прим",
        "руб", "коп", "тыс", "млн", "млрд", "трлн", "шт", "ед", "экз", "кв", "куб", "мин", "макс",
        "ул", "пер", "просп", "наб", "обл", "р-н", "корп", "стр", "оф", "им", "св", "гл", "разд",
        "прил", "рис", "табл", "стб", "гр", "абз", "подп", "пункт", "ред", "изд", "вып", "т.е", "т.к",
        "т.п", "т.д", "т.н", "т.ч", "напр", "тел", "факс", "доп", "англ", "рус", "лат",
        "e.g", "i.e", "etc", "vs", "no", "fig", "approx", "inc", "ltd", "co", "mr", "mrs", "dr",
    ]

    private static func ranges(inLine text: String, _ line: Range<String.Index>) -> [Range<String.Index>] {
        let trimmed = trimmedRange(text, line)
        guard !trimmed.isEmpty else { return [] }
        let content = text[trimmed]
        // Строка таблицы — одно предложение.
        if content.hasPrefix("|"), content.hasSuffix("|") { return [trimmed] }

        var result: [Range<String.Index>] = []
        var start = trimmed.lowerBound
        var index = trimmed.lowerBound
        while index < trimmed.upperBound {
            let character = text[index]
            let next = text.index(after: index)
            if ".!?…".contains(character), isBoundary(text, at: index, sentenceStart: start, lineEnd: trimmed.upperBound) {
                // Знаки подряд («?!», «...») и закрывающие кавычки и скобки —
                // хвост того же предложения.
                var end = next
                while end < trimmed.upperBound, ".!?…»\")".contains(text[end]) { end = text.index(after: end) }
                let piece = trimmedRange(text, start..<end)
                if !piece.isEmpty { result.append(piece) }
                start = end
                index = end
                continue
            }
            index = next
        }
        let tail = trimmedRange(text, start..<trimmed.upperBound)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Кончает ли знак в `index` предложение.
    private static func isBoundary(
        _ text: String, at index: String.Index, sentenceStart: String.Index, lineEnd: String.Index
    ) -> Bool {
        // Дальше пробел, а за ним — начало нового предложения.
        var after = text.index(after: index)
        while after < lineEnd, ".!?…»\")".contains(text[after]) { after = text.index(after: after) }
        guard after < lineEnd, text[after].isWhitespace else { return false }
        var first = after
        while first < lineEnd, text[first].isWhitespace { first = text.index(after: first) }
        guard first < lineEnd else { return false }
        let opener = text[first]
        guard opener.isUppercase || opener.isNumber || "«\"(—–-•●".contains(opener) else { return false }

        guard text[index] == "." else { return true }
        // Слово перед точкой.
        var wordStart = index
        while wordStart > sentenceStart {
            let previous = text.index(before: wordStart)
            guard !text[previous].isWhitespace, text[previous] != "(" else { break }
            wordStart = previous
        }
        let word = text[wordStart..<index]
        let lowered = word.lowercased()
        if abbreviations.contains(lowered) { return false }
        // «т. е.», «т. п.»: одна буква и точка внутри сокращения из двух.
        if word.count == 1, let letter = word.first, letter.isLetter {
            // Инициал или однобуквенное сокращение: «А. С. Пушкин», «т. е.».
            return false
        }
        // Номер пункта в начале строки: «1.», «2.1.», «IV.».
        if wordStart == sentenceStart, isEnumerator(word) { return false }
        return true
    }

    private static func isEnumerator(_ word: Substring) -> Bool {
        guard !word.isEmpty, word.count <= 10 else { return false }
        if word.allSatisfy({ $0.isNumber || $0 == "." }) { return word.first?.isNumber == true }
        return word.allSatisfy { "IVXLCivxlc".contains($0) }
    }

    private static func trimmedRange(_ text: String, _ range: Range<String.Index>) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while upper > lower, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        return lower..<upper
    }
}
