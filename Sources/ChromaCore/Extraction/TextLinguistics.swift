import Foundation
import NaturalLanguage

/// Язык и ключевые слова текста — средствами системы.
///
/// `NaturalLanguage` уже есть в macOS: зависимостью он не считается (правило 6
/// приложения 5), работает локально и быстро — миллисекунда на чанк
/// на определение языка и полторы на разбор слов, измерено.
///
/// **Чего здесь намеренно нет — именованных сущностей.** Живая проверка
/// на русском: в фразе «Инженер Петров из компании „Астра“ составил отчёт
/// в Москве» `NLTagger` не нашёл Петрова вовсе, а «Астру» назвал местом.
/// Английский разбирается точно, русский — нет, и фасет «сущности» на русской
/// базе состоял бы из пропусков и ошибок.
public enum TextLinguistics {
    // MARK: - Язык

    /// Сколько букв нужно, чтобы вопрос «на каком это языке» вообще имел
    /// смысл.
    ///
    /// «Итого: 42» определяется как русский с уверенностью 1.00 — уверенность
    /// эта ни о чём: в строке нет ни одного слова. Такому чанку язык
    /// достаётся от документа, а не выдумывается по двум буквам.
    public static let minimumLettersForLanguage = 12

    /// Код языка (`ru`, `en`, …) или `nil`, если сказать нечего.
    public static func language(of text: String) -> String? {
        guard letterCount(text) >= minimumLettersForLanguage else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    static func letterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character.isLetter { count += 1 }
        }
    }

    // MARK: - Ключевые слова

    /// Сколько ключевых слов оставлять.
    public static let keywordLimit = 8
    /// Короче этого слово ключевым не бывает.
    static let minimumKeywordLength = 4

    /// Ключевые слова в начальной форме, от частых к редким.
    ///
    /// Почему леммы: в русском «отпуска», «отпуску» и «отпуском» — одно слово,
    /// и фасет, где они стоят тремя строками, бесполезен. Леммы `NLTagger`
    /// даёт **точные** — проверено на живом разборе: отпуска → отпуск,
    /// заявлением → заявление, переносятся → переноситься.
    ///
    /// **А вот части речи для русского он определяет неверно** — и это
    /// не мелочь, а развилка. В том же разборе «Отпуск» назван прилагательным,
    /// «оформляется» — существительным, «заявлением» — глаголом, «Отпуска» —
    /// предлогом. Отбор существительных по такой разметке — это отбор наугад.
    /// Для английского разметка точная («runs» → глагол, «backup» →
    /// существительное), и там она используется.
    ///
    /// Поэтому путей два: язык, где частям речи можно верить, отбирается
    /// по ним; русский — по леммам со списком слов, которые есть в любом
    /// тексте. Один общий путь означал бы либо мусор в русских ключевых
    /// словах, либо потерю точности в английских.
    public static func keywords(
        in text: String, language: String? = nil, limit: Int = keywordLimit
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let code = language ?? Self.language(of: text)
        let trustsPartsOfSpeech = code.map { !Self.unreliablePartsOfSpeech.contains($0) } ?? true

        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text

        var counts: [String: Int] = [:]
        var order: [String: Int] = [:]
        var position = 0

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace, .omitOther]
        ) { tag, range in
            position += 1
            if trustsPartsOfSpeech {
                guard let tag, tag == .noun || tag == .otherWord else { return true }
            } else if let tag, Self.alwaysDropped.contains(tag) {
                // Даже неверной разметке можно верить в одном: числа и знаки
                // ключевыми словами не бывают ни в одном языке.
                return true
            }
            // Лемма, а если её нет — само слово: у латиницы и технических
            // терминов внутри русского текста леммы часто не бывает.
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let word = (lemma ?? String(text[range])).lowercased()
            guard word.count >= minimumKeywordLength,
                  !stopWords.contains(word),
                  word.contains(where: { $0.isLetter })
            else { return true }
            counts[word, default: 0] += 1
            if order[word] == nil { order[word] = position }
            return true
        }

        // По частоте, а при равной частоте — по порядку в тексте: слово
        // из первого абзаца важнее такого же из последнего.
        return counts
            .sorted { left, right in
                left.value == right.value
                    ? (order[left.key] ?? 0) < (order[right.key] ?? 0)
                    : left.value > right.value
            }
            .prefix(limit)
            .map(\.key)
    }

    /// Ключевые слова одной строкой: в метаданных ChromaDB списков не бывает
    ///.
    public static func keywordLine(
        in text: String, language: String? = nil, limit: Int = keywordLimit
    ) -> String? {
        let words = keywords(in: text, language: language, limit: limit)
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    /// Языки, для которых разметка частей речи разъезжается настолько, что
    /// отбирать по ней нельзя. Проверено вживую на русском.
    static let unreliablePartsOfSpeech: Set<String> = ["ru", "uk", "be", "bg", "sr", "kk"]

    /// Части речи, которые не бывают ключевыми словами ни при какой разметке.
    static let alwaysDropped: Set<NLTag> = [.number, .punctuation, .whitespace, .other]

    /// Слова, которые есть в любом тексте и потому не значат ничего.
    ///
    /// Список ручной и короткий. Для языков с верной разметкой частей речи
    /// он почти не нужен — там отбор делают существительные; для русского это
    /// единственный фильтр, поэтому здесь и служебные слова, и общие глаголы,
    /// и «слова-наполнители», которые формально существительные, а по смыслу
    /// пусты.
    ///
    /// Все — в начальной форме: сравнение идёт с леммой, а не со словом.
    static let stopWords: Set<String> = [
        // Русский: местоимения, союзы, частицы, вводные
        "который", "этот", "тот", "такой", "весь", "свой", "себя", "каждый",
        "любой", "другой", "самый", "какой", "чтобы", "потому", "поэтому",
        "также", "либо", "если", "когда", "чем", "здесь", "туда", "сюда",
        "очень", "более", "менее", "только", "уже", "ещё", "нужно", "надо",
        // Русский: общие глаголы
        "быть", "мочь", "иметь", "являться", "делать", "сделать", "стать",
        "давать", "получать", "использовать", "применять", "являлся",
        "требоваться", "считать", "указать", "указывать", "приводить",
        // Русский: слова-наполнители
        "год", "время", "случай", "вопрос", "работа", "данные", "система",
        "часть", "число", "раздел", "пункт", "документ", "файл", "результат",
        "образ", "качество", "лист", "строка", "таблица", "рисунок",
        "приложение", "порядок", "процесс", "состав", "объект", "элемент",
        "значение", "уровень", "правило", "форма", "список", "текст",
        // Английский
        "case", "data", "system", "part", "number", "section", "item",
        "document", "file", "result", "value", "example", "figure", "table",
        "page", "note", "way", "thing", "time", "year", "list", "text",
        "process", "level", "form", "object", "element", "order", "rule",
    ]
}
