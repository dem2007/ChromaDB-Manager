import Foundation

/// Поиск места чанка в исходном документе.
///
/// **Зачем отдельный тип и почему он самый важный в просмотрщике.**
/// Совпадение текста чанка с текстом в документе **не гарантировано**:
/// извлечение склеивало переносы, нормализовало пробелы, разворачивало
/// лигатуры, а в PDF порядок чтения мог отличаться от визуального. Наивный
/// поиск подстроки промахивается часто, и функция «показать в документе»
/// работает через раз — а это хуже, чем её отсутствие: человек перестаёт ей
/// верить и больше не нажимает.
///
/// Поэтому четыре шага из H1.2, ровно в этом порядке, и четвёртый —
/// полноправный исход, а не ошибка.
public enum FragmentLocator {

    /// Чем нашлось. Показывается человеку: «нашли по краям» и «нашли целиком»
    /// — разные уровни уверенности, и подсветка по самому длинному предложению
    /// покрывает не весь чанк.
    public enum Strategy: String, Sendable, Equatable {
        /// Полный текст чанка нашёлся как есть.
        case exact
        /// Нашлись начало и конец; подсвечено всё между ними.
        case edges
        /// Нашлось самое длинное предложение чанка.
        case longestSentence
        /// Нашлось, если не считать дефисы.
        case ignoringHyphens

        public var title: String {
            switch self {
            case .exact: return String(localized: "фрагмент найден целиком")
            case .edges: return String(localized: "совпали начало и конец фрагмента")
            case .longestSentence: return String(localized: "совпало самое длинное предложение фрагмента")
            case .ignoringHyphens: return String(localized: "совпало без учёта дефисов и переносов")
            }
        }

        /// Точная ли подсветка. По краям и по предложению — приблизительная,
        /// и говорить об этом надо до того, как человек решит, что приложение
        /// показало не то место.
        public var isExact: Bool { self == .exact }
    }

    public struct Match: Sendable, Equatable {
        /// Диапазон **в исходном тексте**, а не в нормализованном.
        public let range: Range<String.Index>
        public let strategy: Strategy

        public init(range: Range<String.Index>, strategy: Strategy) {
            self.range = range
            self.strategy = strategy
        }
    }

    /// Сколько символов с каждого края берётся на втором шаге.
    ///
    /// 2 называет 40: края совпадают чаще середины — нарезка режет по
    /// границам предложений и абзацев, а портится обычно то, что внутри
    /// (переносы, лигатуры, порядок колонок).
    public static let edgeLength = 40

    /// Ниже этого предложение не считается опознавательным: «Да.» найдётся
    /// в любом документе и подсветит случайное место.
    public static let minimumSentenceLength = 24

    /// Ищет место чанка. `nil` — четвёртый исход H1.2: перейти к странице
    /// без подсветки и честно сказать, что точное место не определено.
    public static func locate(chunk: String, in document: String) -> Match? {
        if let match = locate(chunk: chunk, in: document, ignoringHyphens: false) {
            return match
        }
        // Последняя попытка — не считая дефисы вовсе.
        //
        // Обычная нормализация решает за документ, что `-` в конце строки
        // всегда перенос, и склеивает слово. Извлечение решает иначе и часто
        // правее: `информационно-` / `телекоммуникационной` — составное слово,
        // и дефис в чанке остаётся. Тогда чанк и страница нормализуются
        // по-разному, и подсветка пропадает ровно на тех документах, где таких
        // слов больше всего (замер: 380 случаев на корпусе пользователя).
        //
        // Отдельным шагом, а не заменой правила: слепота к дефисам огрубляет
        // поиск, и человеку об этом говорят — `ignoringHyphens` не считается
        // точным совпадением.
        guard let match = locate(chunk: chunk, in: document, ignoringHyphens: true) else {
            return nil
        }
        return Match(range: match.range, strategy: .ignoringHyphens)
    }

    private static func locate(chunk: String, in document: String, ignoringHyphens: Bool) -> Match? {
        let haystack = NormalisedText(document, ignoringHyphens: ignoringHyphens)
        let needle = NormalisedText.normalise(chunk, ignoringHyphens: ignoringHyphens)
        guard !needle.isEmpty, !haystack.value.isEmpty else { return nil }

        if let range = haystack.range(of: needle) {
            return Match(range: range, strategy: .exact)
        }
        if let range = byEdges(needle: needle, haystack: haystack) {
            return Match(range: range, strategy: .edges)
        }
        if let range = byLongestSentence(needle: needle, haystack: haystack) {
            return Match(range: range, strategy: .longestSentence)
        }
        return nil
    }

    /// Шаг 2: начало и конец.
    ///
    /// Конец ищется **после** начала — иначе на документе, где начало чанка
    /// встречается дважды, подсветка растянулась бы через полстраницы назад.
    static func byEdges(needle: String, haystack: NormalisedText) -> Range<String.Index>? {
        guard needle.count > edgeLength * 2 else { return nil }
        let head = String(needle.prefix(edgeLength))
        let tail = String(needle.suffix(edgeLength))
        // Оба конца ищутся в нормализованных координатах: сравнивать «после
        // начала» можно только в одной системе координат, а перевод в
        // исходный текст делается один раз, уже над готовым диапазоном.
        guard let headRange = haystack.normalisedRange(of: head) else { return nil }
        guard let tailRange = haystack.normalisedRange(of: tail, after: headRange.upperBound)
        else { return nil }
        return haystack.original(of: headRange.lowerBound..<tailRange.upperBound)
    }

    /// Шаг 3: самое длинное предложение.
    ///
    /// Длинное — потому что оно с наибольшей вероятностью уникально в
    /// документе; короткое совпало бы где угодно.
    static func byLongestSentence(needle: String, haystack: NormalisedText) -> Range<String.Index>? {
        for sentence in sentences(of: needle) {
            if let range = haystack.range(of: sentence) { return range }
        }
        return nil
    }

    /// Предложения чанка, от самого длинного к короткому.
    static func sentences(of text: String) -> [String] {
        text
            .split(whereSeparator: { ".!?;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minimumSentenceLength }
            .sorted { $0.count > $1.count }
    }
}

/// Текст, приведённый к сравнимому виду, **с картой обратно в оригинал**.
///
/// Без карты подсветка невозможна: искать надо в нормализованном тексте
/// (иначе не найдём), а выделять — в исходном (иначе выделим не то место).
/// Поэтому на каждый символ нормализованной строки хранится позиция в
/// исходной.
struct NormalisedText {
    let value: String
    /// `origins[i]` — где в исходном тексте начинается i-й символ `value`.
    private let origins: [String.Index]
    /// Конец исходного символа — нужен, чтобы подсветка включала его целиком.
    private let ends: [String.Index]

    init(_ source: String, ignoringHyphens: Bool = false) {
        var value = ""
        var origins: [String.Index] = []
        var ends: [String.Index] = []
        var index = source.startIndex
        var pendingSpace = false
        /// Дефис, судьба которого ещё не решена: за переносом строки он
        /// исчезает вместе с ней («приме-\nнение» → «применение»), в любом
        /// другом месте остаётся («ИТ-инфраструктура»). Решает следующий
        /// символ, поэтому дефис придерживается, а не пишется сразу — первая
        /// редакция писала, и склейка не работала вовсе.
        var heldHyphen: (index: String.Index, end: String.Index)?

        func flushHyphen() {
            guard let held = heldHyphen else { return }
            heldHyphen = nil
            // В слепом режиме дефис не пишется никуда: обе стороны сравнения
            // приведены одинаково, и `ИТ-инфраструктура` совпадает
            // с `ИТинфраструктура`.
            guard !ignoringHyphens else { return }
            value.append("-")
            origins.append(held.index)
            ends.append(held.end)
        }

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)

            if character.isNewline {
                if heldHyphen != nil {
                    // Перенос слова: и дефис, и перевод строки исчезают.
                    heldHyphen = nil
                    index = next
                    continue
                }
                if !value.isEmpty { pendingSpace = true }
                index = next
                continue
            }

            if character.isWhitespace {
                flushHyphen()
                if !value.isEmpty { pendingSpace = true }
                index = next
                continue
            }

            // Мягкий перенос не значит ничего, кроме «здесь можно разорвать».
            if character == "\u{00AD}" {
                index = next
                continue
            }

            if character == "-" || character == "\u{2010}" {
                flushHyphen()
                heldHyphen = (index, next)
                index = next
                continue
            }

            flushHyphen()
            if pendingSpace {
                value.append(" ")
                origins.append(index)
                ends.append(index)
                pendingSpace = false
            }

            // Лигатуры и диакритика раскладываются, и один исходный символ
            // может дать несколько — все они указывают на одну и ту же
            // позицию в оригинале.
            //
            // Совместимая декомпозиция обязательна и делается **до** folding:
            // `folding` лигатуру не трогает вовсе (проверено: «ﬃ» остаётся
            // одним символом), а в PDF она встречается постоянно, и без этого
            // шага целые английские абзацы не находились бы.
            let folded = String(character)
                .precomposedStringWithCompatibilityMapping
                .lowercased()
                .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            for scalarCharacter in folded {
                value.append(scalarCharacter)
                origins.append(index)
                ends.append(next)
            }
            index = next
        }
        flushHyphen()

        self.value = value
        self.origins = origins
        self.ends = ends
    }

    /// Приведение строки, которую ищут: карта для неё не нужна.
    static func normalise(_ text: String, ignoringHyphens: Bool = false) -> String {
        NormalisedText(text, ignoringHyphens: ignoringHyphens).value
    }

    /// Диапазон в **исходном** тексте для найденного в нормализованном.
    func range(of needle: String, after start: String.Index? = nil) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        let searchStart = start ?? value.startIndex
        guard searchStart <= value.endIndex,
              let found = value.range(of: needle, range: searchStart..<value.endIndex)
        else { return nil }
        return original(of: found)
    }

    /// То же, но диапазон остаётся в нормализованном тексте — для поиска
    /// «конца после начала», где сравнивать надо в одной системе координат.
    func normalisedRange(of needle: String, after start: String.Index? = nil) -> Range<String.Index>? {
        let searchStart = start ?? value.startIndex
        guard searchStart <= value.endIndex else { return nil }
        return value.range(of: needle, range: searchStart..<value.endIndex)
    }

    func original(of range: Range<String.Index>) -> Range<String.Index>? {
        let lower = value.distance(from: value.startIndex, to: range.lowerBound)
        let upper = value.distance(from: value.startIndex, to: range.upperBound)
        guard lower < origins.count, upper > 0, upper <= ends.count else { return nil }
        let from = origins[lower]
        let to = ends[upper - 1]
        guard from < to else { return nil }
        return from..<to
    }
}
