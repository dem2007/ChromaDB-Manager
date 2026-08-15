import Foundation

/// Сшивка визуальных строк PDF в абзацы.
///
/// **Зачем.** PDFKit отдаёт текст страницы так, как он лёг на бумагу: перевод
/// строки стоит в конце каждой визуальной строки, а абзацных границ нет вовсе.
/// Замер на 400 файлах пользователя: 8408 одиночных `\n` против 203 двойных —
/// и все 203 поставил сам экстрактор между страницами. Один перенос на 44
/// знака: это ширина набора, а не конец мысли.
///
/// **Чем это плохо для нарезки.** Разделители recursive идут в порядке
/// `\n\n`, `\n`, `. `, ` `. На таком тексте `\n\n` разделяет страницы,
/// а `\n` срабатывает раньше `. ` — значит **граница чанка всегда приходится
/// на конец визуальной строки, то есть на середину предложения**. Adaptive
/// хуже: её «блоки» — куски между `\n\n`, то есть целые страницы, и плотность,
/// по которой она подбирает размер, считается по странице целиком. Замер до
/// и после сшивки: доля чанков, кончающихся на границе предложения, 13.6% →
/// 33.0% (и это считая табличные страницы, где сшивка намеренно не делается).
///
/// **Границы абзацев определяются шириной набора.** В свёрстанном тексте все
/// строки абзаца, кроме последней, идут во всю ширину; строка заметно короче —
/// это конец абзаца. Ширина берётся как 90-й процентиль длин строк страницы,
/// а не как максимум: заголовок или строка с разрядкой завышают максимум.
public enum PDFTextReflow {
    /// Доля строк во всю ширину, ниже которой страница считается не связным
    /// текстом, а таблицей или бланком.
    ///
    /// На таблице сшивать нечего: там строка — это строка таблицы, и склеить
    /// её со следующей значило бы смешать две записи. Такая страница остаётся
    /// как была, и нарезка ведёт себя на ней ровно как до этой правки.
    /// Из 6458 страниц замера сшито 2670, оставлено как есть 3788.
    static let proseShare = 0.45

    /// Строка короче этой доли от ширины набора — конец абзаца.
    static let shortLine = 0.80

    /// Ниже этого числа строк о ширине набора говорить нечего.
    static let minimumLines = 3

    /// Уже этого набора не бывает — на такой странице «полная строка» ничего
    /// не значит.
    static let minimumWidth = 30

    // MARK: - Словарь документа

    /// Что документ знает о своих же словах — нужно, чтобы решить судьбу
    /// дефиса на конце строки.
    ///
    /// **Почему без этого нельзя.** Дефис в конце строки бывает двух родов,
    /// и они требуют противоположного обращения:
    ///
    /// * перенос по слогам — `обеспече-` / `ния`, дефис снять и склеить;
    /// * составное слово, разорванное по своему же дефису — `информационно-` /
    ///   `телекоммуникационной`, дефис оставить.
    ///
    /// Замер на корпусе пользователя: 1313 первых и 380 вторых. Любое
    /// одно правило портит одну из групп, а в делопроизводственных документах
    /// (Word без автопереноса) вторая группа — вообще единственная: там
    /// «слепая» склейка выдала бы `информационнотелекоммуникационной`.
    ///
    /// Решает сам документ: если та же форма встречается в нём слитно — это
    /// перенос, если через дефис — составное. Так решается 66% случаев.
    /// Остальные — по тому, пользуется ли документ автопереносом вообще:
    /// это настройка на весь файл, и она либо включена, либо нет.
    public struct Vocabulary: Sendable {
        let words: Set<String>
        /// В документе нашёлся хоть один несомненный перенос по слогам —
        /// значит автоперенос включён, и неопознанные случаи тоже переносы.
        let usesHyphenation: Bool

        /// Словарь документа, который ничего о себе не сказал: дефис тогда
        /// остаётся на месте.
        public static let empty = Vocabulary(words: [], usesHyphenation: false)
    }

    /// Строит словарь по всем страницам сразу: вопрос «как это слово написано
    /// в других местах» на одной странице ответа обычно не имеет.
    public static func vocabulary(ofPages pages: [String]) -> Vocabulary {
        let lines = pages.flatMap { page in
            page.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard !lines.isEmpty else { return .empty }

        // Слова с разрыва в словарь не попадают ни слитно, ни через дефис —
        // иначе словарь подтвердил бы сам себя, и ответ был бы всегда «да».
        var brokenLeft: Set<Int> = []
        var brokenRight: Set<Int> = []
        var breaks: [(left: String, right: String)] = []
        for position in lines.indices {
            guard let piece = brokenWord(at: position, in: lines) else { continue }
            breaks.append(piece)
            brokenLeft.insert(position)
            brokenRight.insert(position + 1)
        }
        guard !breaks.isEmpty else { return .empty }

        var words: Set<String> = []
        for (position, line) in lines.enumerated() {
            var tokens = Self.tokens(of: line)
            if brokenLeft.contains(position), !tokens.isEmpty { tokens.removeLast() }
            if brokenRight.contains(position), !tokens.isEmpty { tokens.removeFirst() }
            words.formUnion(tokens)
        }

        var syllable = 0
        var compound = 0
        for piece in breaks {
            let solid = piece.left + piece.right
            let dashed = piece.left + "-" + piece.right
            let hasSolid = words.contains(solid)
            let hasDashed = words.contains(dashed)
            if hasSolid && !hasDashed { syllable += 1 }
            if hasDashed && !hasSolid { compound += 1 }
        }
        return Vocabulary(words: words, usesHyphenation: syllable > compound)
    }

    /// Разорванное концом строки слово — левая и правая половины в нижнем
    /// регистре, или `nil`, если на этой границе слово не рвётся.
    ///
    /// Строчная буква в начале следующей строки обязательна: с прописной
    /// начинается новое предложение, а не продолжение слова, и дефис там —
    /// тире или знак списка.
    static func brokenWord(at position: Int, in lines: [String]) -> (left: String, right: String)? {
        guard position + 1 < lines.count else { return nil }
        let line = lines[position]
        guard line.hasSuffix("-") || line.hasSuffix("\u{2010}") else { return nil }
        let next = lines[position + 1]
        guard let first = next.first, first.isLetter, first.isLowercase else { return nil }
        guard let left = tokens(of: line).last, let right = tokens(of: next).first else { return nil }
        guard left.count >= 2, right.count >= 2 else { return nil }
        return (left, right)
    }

    /// Слова строки в нижнем регистре: буквы и внутренние дефисы, всё
    /// остальное — разделитель.
    static func tokens(of line: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in line.lowercased() {
            if character.isLetter || character == "-" || character == "\u{2010}" {
                current.append(character == "\u{2010}" ? "-" : character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Одна страница

    /// Сшивает строки страницы в абзацы, разделённые пустой строкой.
    ///
    /// Страница обрабатывается отдельно и **до** склейки документа — тогда
    /// смещения страниц, которые собирает экстрактор, остаются точными:
    /// они считаются уже по сшитому тексту.
    public static func page(_ text: String, vocabulary: Vocabulary = .empty) -> String {
        let rawLines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let filled = rawLines.filter { !$0.isEmpty }
        guard filled.count >= minimumLines else { return filled.joined(separator: "\n") }

        let lengths = filled.map(\.count).sorted()
        let width = lengths[min(lengths.count - 1, Int(Double(lengths.count) * 0.9))]
        guard width >= minimumWidth else { return filled.joined(separator: "\n") }

        let full = filled.filter { Double($0.count) >= Double(width) * shortLine }.count
        guard Double(full) / Double(filled.count) >= proseShare else {
            return filled.joined(separator: "\n")
        }

        var paragraphs: [String] = []
        var current = ""
        var currentLastLineLength = 0

        for line in rawLines {
            // Пустая строка в исходнике — граница абзаца, поставленная самим
            // документом. Такие встречаются редко, но если стоят — они точнее
            // любой догадки по ширине.
            guard !line.isEmpty else {
                if !current.isEmpty { paragraphs.append(current); current = "" }
                continue
            }
            guard !current.isEmpty else {
                current = line
                currentLastLineLength = line.count
                continue
            }
            if startsNewBlock(line) || Double(currentLastLineLength) < Double(width) * shortLine {
                paragraphs.append(current)
                current = line
            } else {
                current = joined(current, line, vocabulary: vocabulary)
            }
            currentLastLineLength = line.count
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Приклеивает строку к абзацу, разбираясь с дефисом на стыке.
    static func joined(_ paragraph: String, _ line: String, vocabulary: Vocabulary) -> String {
        guard let last = paragraph.last, last == "-" || last == "\u{2010}",
              let first = line.first, first.isLetter, first.isLowercase,
              let left = tokens(of: paragraph).last, let right = tokens(of: line).first,
              left.count >= 2, right.count >= 2
        else {
            return paragraph + " " + line
        }

        let hasSolid = vocabulary.words.contains(left + right)
        let hasDashed = vocabulary.words.contains(left + "-" + right)
        if hasSolid && !hasDashed { return String(paragraph.dropLast()) + line }
        if hasDashed && !hasSolid { return paragraph + line }
        // Документ о самом себе ничего не сказал — верим его настройке
        // переносов. Нет и её — дефис остаётся: выдуманное слитное слово
        // не найдёт ни поиск, ни модель, а слово через дефис хотя бы
        // распадётся на два осмысленных куска.
        return vocabulary.usesHyphenation ? String(paragraph.dropLast()) + line : paragraph + line
    }

    /// Строка, которая начинает новый блок, чем бы ни кончилась предыдущая.
    ///
    /// Знак списка и номер пункта — разметка, уцелевшая в тексте, и склеивать
    /// по ней нельзя: перечисление из десяти пунктов слиплось бы в один абзац.
    static func startsNewBlock(_ line: String) -> Bool {
        if startsWithListMarker(line) { return true }
        return sectionWords.contains { line.hasPrefix($0) }
    }

    /// Знак перечисления или номер пункта в начале строки.
    ///
    /// Отдельно от `startsNewBlock`, потому что спрашивают об этом двое:
    /// сшивка — чтобы отделить пункт в свой блок, и `ListLeadIns` — чтобы
    /// понять, где список кончился. Два своих правила разошлись бы, и одно
    /// место считало бы пунктом то, что другое пунктом не считает.
    static func startsWithListMarker(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if bullets.contains(first) { return true }
        // Знаки, которые бывают маркером, а бывают частью текста, требуют
        // пробела за собой: `- пункт` — перечисление, `-5 градусов`
        // и `*важно*` — нет. Без этого условия дефисом начинались бы
        // отрицательные числа, а звёздочкой — выделение Markdown.
        if asciiBullets.contains(first) {
            return line.dropFirst().first == " "
        }
        guard first.isNumber else { return false }
        // «1. », «1.2. », «1) » — цифры, точки, затем скобка или пробел.
        var sawSeparator = false
        for character in line.prefix(12) {
            if character.isNumber { continue }
            if character == "." { sawSeparator = true; continue }
            if character == ")" { return true }
            return sawSeparator && character == " "
        }
        return false
    }

    /// Знаки списка, какие встречаются в PDF. Не один `•`: замер показал
    /// и `●`, и `▪`, и тире в роли маркера.
    static let bullets: Set<Character> = [
        "•", "●", "○", "◦", "▪", "▫", "‣", "·", "§", "–", "—", "−",
    ]

    /// Маркеры Markdown и простого текста. Требуют пробела за собой —
    /// сами по себе они слишком обычные знаки.
    static let asciiBullets: Set<Character> = ["-", "+", "*"]

    static let sectionWords = [
        "Статья", "Глава", "Раздел", "Приложение", "Пункт", "Часть",
        "Article", "Chapter", "Section", "Appendix",
    ]
}
