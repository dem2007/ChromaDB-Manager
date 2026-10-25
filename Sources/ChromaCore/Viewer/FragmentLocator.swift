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
        /// Кусок — таблица: нашлись первая и последняя узнаваемые её ячейки,
        /// подсвечено всё между ними.
        case tableCells
        /// Нашлись по порядку все части куска — строки, пункты, предложения,
        /// ячейки; разошлась только запись: «— » пункта против «•», «|»
        /// таблицы, номер заголовка.
        case allParts
        /// Нашлась по порядку бо́льшая часть куска.
        case mostParts

        public var title: String {
            switch self {
            case .exact: return String(localized: "фрагмент найден целиком")
            case .edges: return String(localized: "совпали начало и конец фрагмента")
            case .longestSentence: return String(localized: "совпало самое длинное предложение фрагмента")
            case .ignoringHyphens: return String(localized: "совпало без учёта дефисов и переносов")
            case .tableCells: return String(localized: "таблица найдена по первой и последней ячейкам")
            case .allParts: return String(localized: "фрагмент найден по частям")
            case .mostParts: return String(localized: "совпала бо́льшая часть фрагмента")
            }
        }

        /// Точная ли подсветка. По краям и по предложению — приблизительная,
        /// и говорить об этом надо до того, как человек решит, что приложение
        /// показало не то место.
        ///
        /// Все части по порядку — тоже точно: текст куска на месте целиком,
        /// разнится только разметка, которую добавило извлечение.
        public var isExact: Bool { self == .exact || self == .allParts }
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
    ///
    /// - Parameter includingTableCells: пробовать ли последним шаг по ячейкам
    /// таблицы. Поиск по страницам PDF его выключает и делает
    ///   отдельным проходом: слабый шаг на одной странице не должен
    ///   опережать точное совпадение на соседней.
    public static func locate(chunk: String, in document: String, includingTableCells: Bool = true) -> Match? {
        if let match = locateText(chunk: chunk, in: document) { return match }
        return includingTableCells ? locateByTableCells(chunk: chunk, in: document) : nil
    }

    /// Шаги по тексту: целиком, по краям, по предложению — и то же без учёта
    /// дефисов.
    static func locateText(chunk: String, in document: String) -> Match? {
        // Целиком и по частям — сначала с дефисами, потом без них; края и
        // самое длинное предложение — только потом. Они слабее:
        // начало куска, повторённое в документе выше (оглавление, такой же
        // абзац в соседнем разделе), растягивало подсветку на сотни страниц,
        // а предложение из шаблонного абзаца находилось в чужом разделе.
        //
        // Без дефисов — отдельным заходом, а не заменой правила.
        // Обычная нормализация решает за документ, что `-` в конце строки
        // всегда перенос, и склеивает слово. Извлечение решает иначе и часто
        // правее: `информационно-` / `телекоммуникационной` — составное
        // слово, и дефис в чанке остаётся. Слепота к дефисам огрубляет поиск,
        // и человеку об этом говорят: `ignoringHyphens` не считается точным
        // совпадением.
        //
        // Края и предложение считаются сразу, пока нормализованный документ
        // в памяти, а возвращаются, только если и без дефисов ни целиком, ни
        // по частям кусок не нашёлся: две нормализации большого документа
        // разом — это десятки мегабайт (ревью…).
        var approximate: Match?
        for ignoringHyphens in [false, true] {
            let haystack = NormalisedText(document, ignoringHyphens: ignoringHyphens)
            let needle = NormalisedText.normalise(chunk, ignoringHyphens: ignoringHyphens)
            guard !needle.isEmpty, !haystack.value.isEmpty else { continue }
            // Без дефисов — значит не точно. Но «нашлась бо́льшая часть»
            // важнее сказать, чем «без дефисов»: иначе человек решит, что
            // подсвечен весь кусок.
            func blind(_ match: Match) -> Match {
                guard ignoringHyphens, match.strategy != .mostParts else { return match }
                return Match(range: match.range, strategy: .ignoringHyphens)
            }
            if let range = haystack.range(of: needle) {
                return blind(Match(range: range, strategy: .exact))
            }
            if let found = byParts(chunk: chunk, haystack: haystack, ignoringHyphens: ignoringHyphens) {
                return blind(Match(range: found.range, strategy: found.complete ? .allParts : .mostParts))
            }
            guard approximate == nil else { continue }
            if let range = byEdges(needle: needle, haystack: haystack) {
                approximate = blind(Match(range: range, strategy: .edges))
            } else if let range = byLongestSentence(needle: needle, haystack: haystack) {
                approximate = blind(Match(range: range, strategy: .longestSentence))
            }
        }
        return approximate
    }

    /// Только шаг по ячейкам таблицы — с дефисами и без них.
    public static func locateByTableCells(chunk: String, in document: String) -> Match? {
        guard !tableRows(of: chunk).isEmpty else { return nil }
        for ignoringHyphens in [false, true] {
            let haystack = NormalisedText(document, ignoringHyphens: ignoringHyphens)
            if let range = byTableCells(chunk: chunk, haystack: haystack, ignoringHyphens: ignoringHyphens) {
                return Match(range: range, strategy: .tableCells)
            }
        }
        return nil
    }

    // MARK: - По частям

    /// Часть куска: строка, пункт списка, предложение или ячейка таблицы —
    /// приведённая к сравнимому виду, и где она стоит в самом куске.
    struct Part {
        let text: String
        /// Место в куске, в знаках, — по нему судят, какой промежуток между
        /// частями в документе ещё свой.
        let start: Int
        let end: Int
    }

    /// Часть короче этого опорой не служит — как и короткая ячейка.
    static let minimumPartLength = minimumCellLength
    /// Какая доля текста частей должна найтись, чтобы место считалось
    /// найденным. Меньше — это уже не кусок, а пара совпавших фраз, и
    /// честнее перейти к краям и предложению.
    static let minimumPartsShare = 0.5
    /// Сколько мест одной части перебирается. Часть, стоящая в документе
    /// сотни раз, места не определяет, а перебор всех сделал бы шаг
    /// квадратичным.
    static let maximumOccurrences = 200
    /// Промежуток между соседними частями в документе сверх того, что стоит
    /// между ними в куске: колонтитул, номер страницы, подпись рисунка.
    static let allowedGap = 300

    /// Шаг «по частям».
    ///
    /// **Что было.** Кусок искался целиком, потом по краям — первые и
    /// последние сорок знаков, — потом по самому длинному предложению. Замер
    /// на 440 результатах прогона по «Базе»: целиком нашлось 13 %, по краям —
    /// 18 %, и у трети найденных по краям подсветка была шире куска в
    /// десятки и сотни раз. Самое длинное предложение подсвечивало 43 %
    /// кусков — одним предложением, и нередко чужим. Причины три:
    /// - кусок записан не так, как документ показывает просмотрщик: пункт
    ///   списка начинается с «— », а у Word — с «•»; таблица записана через
    ///   «|»; номер заголовка «12.6.4» в тексте Word не стоит вовсе;
    /// - начало куска находилось в первом из одинаковых мест: в оглавлении,
    ///   в таком же абзаце соседнего раздела (в большом ТЗ один и тот же
    ///   типовой абзац стоит четыре раза), — и подсветка тянулась оттуда;
    /// - самое длинное предложение шаблонного абзаца есть в каждом разделе.
    ///
    /// **Как теперь.** Кусок разбирается на части без разметки извлечения.
    /// В документе ищется цепочка: части по порядку, каждая — недалеко за
    /// предыдущей (не дальше, чем между ними в куске, вдвое, плюс
    /// `allowedGap`). Берётся цепочка с наибольшим текстом, подсвечивается от
    /// её первой части до последней. Повтор начала или оглавление цепочку не
    /// уводят: за ними нет остальных частей.
    ///
    /// - Returns: диапазон и признак «нашлись все части».
    static func byParts(chunk: String, haystack: NormalisedText, ignoringHyphens: Bool) -> (range: Range<String.Index>, complete: Bool)? {
        let split = self.parts(of: chunk, ignoringHyphens: ignoringHyphens)
        let parts = split.anchors
        guard !parts.isEmpty else { return nil }
        let lengths = parts.map { $0.text.utf16.count }
        let total = lengths.reduce(0, +)
        let text = NSString(string: haystack.value)

        // Места всех частей, по порядку в документе.
        var nodes: [(part: Int, start: Int, end: Int)] = []
        for (index, part) in parts.enumerated() {
            for found in wholeOccurrences(of: part.text, in: text) {
                nodes.append((index, found.location, NSMaxRange(found)))
            }
        }
        guard !nodes.isEmpty else { return nil }
        nodes.sort { $0.start != $1.start ? $0.start < $1.start : $0.part < $1.part }

        // Самая длинная цепочка: части по порядку куска, каждая — за
        // предыдущей и не дальше дозволенного.
        let longestReach = 2 * chunk.count + allowedGap + (lengths.max() ?? 0)
        var score = [Int](repeating: 0, count: nodes.count)
        var previous = [Int?](repeating: nil, count: nodes.count)
        var best = 0
        for k in nodes.indices {
            let node = nodes[k]
            let length = lengths[node.part]
            score[k] = length
            var j = k - 1
            while j >= 0, node.start - nodes[j].start <= longestReach {
                let before = nodes[j]
                if before.part < node.part, before.end <= node.start,
                   node.start - before.end <= 2 * max(0, parts[node.part].start - parts[before.part].end) + allowedGap,
                   score[j] + length > score[k] {
                    score[k] = score[j] + length
                    previous[k] = j
                }
                j -= 1
            }
            if score[k] > score[best] { best = k }
        }
        guard Double(score[best]) >= Double(total) * minimumPartsShare else { return nil }

        var first = best
        var count = 1
        while let before = previous[first] {
            first = before
            count += 1
        }
        let lower = String.Index(utf16Offset: nodes[first].start, in: haystack.value)
        let upper = String.Index(utf16Offset: nodes[best].end, in: haystack.value)
        guard let range = haystack.original(of: lower..<upper) else { return nil }
        // Целиком — когда нашлись все опоры и до первой из них и после
        // последней в куске почти ничего нет. Строки из коротких ячеек и
        // повторы опорой не служат: стоят они в конце куска — подсветка до
        // них не доходит, и точной она не считается (ревью…).
        let complete = count == parts.count
            && parts[0].start - split.contentStart <= edgeLength
            && split.contentEnd - parts[parts.count - 1].end <= edgeLength
        return (range, complete)
    }

    /// Части куска и где в нём кончается содержимое.
    struct Parts {
        /// Опоры: части не короче `minimumPartLength`, каждая — одна в куске.
        let anchors: [Part]
        /// Начало первой и конец последней части любой длины — всё, что
        /// стоит в куске, кроме шапки таблицы и разделителя под ней.
        let contentStart: Int
        let contentEnd: Int
    }

    /// Части куска: ячейки таблиц без шапки, пункты, предложения — без меток
    /// списка, номеров заголовков и «|». Часть, стоящая в куске больше
    /// одного раза (раздел, повторённый в каждой строке), опорой не служит:
    /// в документе она одна.
    static func parts(of chunk: String, ignoringHyphens: Bool) -> Parts {
        var pieces: [(text: String, start: Int, end: Int)] = []
        var offset = 0
        let lines = chunk.components(separatedBy: "\n")
        var headers: [String] = []
        for (number, line) in lines.enumerated() {
            defer { offset += line.count + 1 }
            if TableText.isRow(line) {
                guard !TableText.isSeparator(line) else { continue }
                // Шапка таблицы опорой не служит (как и у ячеек): она
                // повторена в каждом куске, а в документе стоит только над
                // таблицей, и цепочка тянулась бы к ней через чужие строки.
                if number + 1 < lines.count, TableText.isSeparator(lines[number + 1]) {
                    headers = TableText.cells(of: line).filter { !$0.isEmpty }
                    continue
                }
                // Ячейка — тоже предложениями: в прайсе ячейка бывает целым
                // абзацем («Сервер тип 7 … в составе: CPU …»), а PDFKit
                // перемежает её строки со значениями соседних колонок, и
                // целиком она на странице не стоит.
                var position = offset
                for cell in TableText.cells(of: line) {
                    pieces += sentences(of: withoutRecordLabels(cell, headers: headers), at: position, splittingAtCommas: true)
                    position += cell.count + 3
                }
                continue
            }
            pieces += sentences(of: line, at: offset)
        }
        var parts: [Part] = []
        var seen: [String: Int] = [:]
        var contentStart: Int?
        var contentEnd = 0
        for piece in pieces {
            let text = NormalisedText.normalise(piece.text, ignoringHyphens: ignoringHyphens)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .;!?:,"))
            guard !text.isEmpty else { continue }
            contentStart = contentStart ?? piece.start
            contentEnd = piece.end
            guard text.count >= minimumPartLength else { continue }
            seen[text, default: 0] += 1
            parts.append(Part(text: text, start: piece.start, end: piece.end))
        }
        return Parts(
            anchors: parts.filter { seen[$0.text] == 1 },
            contentStart: contentStart ?? 0,
            contentEnd: contentEnd
        )
    }

    /// Ячейка без пометок, которые дописало извлечение: строки
    /// нумерованной записи сводятся в одну, и значения соседних колонок
    /// встают в скобки с заголовком — «Процессор модели А … 100 Вт
    /// (Кол-во, шт.: 2); Память …». В документе этих скобок нет: количество
    /// стоит своей колонкой, и ни одна часть такой ячейки не находилась.
    /// Снимаются только скобки, начатые заголовком этой же таблицы, — свои
    /// скобки текста («(Архив)») остаются.
    static func withoutRecordLabels(_ cell: String, headers: [String]) -> String {
        guard !headers.isEmpty, cell.contains("(") else { return cell }
        var result = ""
        var rest = Substring(cell)
        while let open = rest.firstIndex(of: "(") {
            let inside = rest[rest.index(after: open)...]
            guard headers.contains(where: { inside.hasPrefix($0 + ": ") }),
                  let close = inside.firstIndex(of: ")")
            else {
                result += rest[...open]
                rest = inside
                continue
            }
            result += rest[..<open].reversed().drop(while: \.isWhitespace).reversed()
            rest = inside[inside.index(after: close)...]
        }
        return result + rest
    }

    /// Предложения текста — с местом каждого в куске и без метки списка в
    /// начале. Граница — «.», «;», «!», «?» или «:» перед пробелом: «4.2.15»
    /// и «2.2» не режутся.
    ///
    /// Метка снимается у каждого предложения, а не только у строки: список
    /// внутри ячейки и пункты после двоеточия («типов: — заполнение…; —
    /// события…») стоят в одной строке куска (ревью…).
    ///
    /// Ячейка режется и по запятым: длинное значение («Модуль памяти,
    /// объём от 8 ГБ, частота от 3000 МГц, …») PDF переносит на
    /// несколько строк, и подпись строки, стоящая по центру ячейки, встаёт в
    /// его середину. Целиком такое значение на странице не стоит, а его
    /// перечисленные через запятую части — стоят.
    private static func sentences(
        of text: String, at offset: Int, splittingAtCommas: Bool = false
    ) -> [(text: String, start: Int, end: Int)] {
        let characters = Array(text)
        let boundaries: String = splittingAtCommas ? ".;!?:," : ".;!?:"
        var result: [(text: String, start: Int, end: Int)] = []
        var start = 0
        for index in characters.indices {
            let closes = boundaries.contains(characters[index])
                && (index + 1 == characters.count || characters[index + 1].isWhitespace)
            guard closes || index + 1 == characters.count else { continue }
            let sentence = String(characters[start...index])
            let marker = listMarker.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence))
                .flatMap { Range($0.range, in: sentence) }
                .map { sentence.distance(from: sentence.startIndex, to: $0.upperBound) } ?? 0
            result.append((String(sentence.dropFirst(marker)), offset + start + marker, offset + index + 1))
            start = index + 1
        }
        return result
    }

    /// Метка в начале строки, которой в документе может не быть: пункт
    /// списка («— », «- », «• », «а) », «1) »), номер заголовка или пункта
    /// («12.6.4 », «4.2.15. »), заголовок Markdown.
    static let listMarker = try! NSRegularExpression(pattern: #"^\s*(?:[-–—‒−•*·▪◦]+|#+|\d+(?:\.\d+)+\.?|\d+[.)]|[а-яa-z][.)])\s+"#)

    /// Места части в документе — целиком, а не внутри длинного слова:
    /// «процессор тип 1» не находится в «процессор тип 12», а «intel xeon
    /// 6248» — в «intel xeon 6248r». Одно правило для частей и для ячеек
    /// таблицы.
    static func wholeOccurrences(
        of needle: String, in text: NSString, from start: Int = 0, limit: Int = maximumOccurrences
    ) -> [NSRange] {
        let target = needle as NSString
        guard target.length > 0 else { return [] }
        func isWord(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return true }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        let opensWithWord = isWord(target.character(at: 0))
        let closesWithWord = isWord(target.character(at: target.length - 1))
        var result: [NSRange] = []
        var from = start
        while from < text.length, result.count < limit {
            let found = text.range(of: needle, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            from = found.location + 1
            if opensWithWord, found.location > 0, isWord(text.character(at: found.location - 1)) { continue }
            if closesWithWord, NSMaxRange(found) < text.length, isWord(text.character(at: NSMaxRange(found))) { continue }
            result.append(found)
        }
        return result
    }

    /// Ячейка короче этого опорой не служит: «1 шт.» и «да» стоят по всей
    /// странице и подсветили бы случайное место.
    static let minimumCellLength = 12
    /// Подсветка длиннее куска во столько раз — уже не он. У таблицы
    /// последняя ячейка нашлась где-то дальше по странице, и подсвечивается
    /// только начало; у краёв конец принадлежит чужому месту, и края не
    /// засчитываются.
    static let maximumSpread = 3

    /// Шаг 4 для таблиц.
    ///
    /// Кусок таблицы — Markdown: «|» между ячейками, строка «| --- |»,
    /// повторённая шапка, объединённые ячейки в каждой строке. В тексте
    /// документа ничего этого нет, а PDFKit к тому же читает таблицу не
    /// строками: «12. Узел тип 5 Узел модели Б 13. …», а
    /// колонку «1 шт.» — отдельно. Ни текст целиком, ни края, ни
    /// предложения такого куска на странице не найдутся, и любой кусок
    /// таблицы PDF открывался страницей без подсветки.
    ///
    /// Ячейки же стоят на странице как есть. Начало — самая ранняя на
    /// странице из опорных ячеек первой строки, где такие нашлись; конец —
    /// самая поздняя после начала из опорных ячеек последней такой строки.
    /// Шапка куска в счёт не идёт: она повторена в нём, а на странице стоит
    /// только сверху таблицы.
    static func byTableCells(chunk: String, haystack: NormalisedText, ignoringHyphens: Bool) -> Range<String.Index>? {
        let rows = anchorRows(of: chunk, ignoringHyphens: ignoringHyphens)
        guard !rows.isEmpty else { return nil }
        let text = NSString(string: haystack.value)

        var head: Range<String.Index>?
        var headRow = 0
        for (index, row) in rows.enumerated() {
            let found = row.compactMap { wholeCell($0, in: haystack, searching: text, after: nil) }
            if let earliest = found.min(by: { $0.lowerBound < $1.lowerBound }) {
                head = earliest
                headRow = index
                break
            }
        }
        guard let head else { return nil }

        var end = head.upperBound
        for row in rows[headRow...].reversed() {
            let found = row.compactMap { wholeCell($0, in: haystack, searching: text, after: head.upperBound) }
            if let latest = found.max(by: { $0.upperBound < $1.upperBound }) {
                end = latest.upperBound
                break
            }
        }
        let spread = haystack.value.distance(from: head.lowerBound, to: end)
        if spread > chunk.count * maximumSpread { end = head.upperBound }
        return haystack.original(of: head.lowerBound..<end)
    }

    /// Опорные ячейки по строкам куска: узнаваемые — не короче
    /// `minimumCellLength` — и свои у строки.
    ///
    /// Значение, стоящее в нескольких строках куска, — раздел или категория,
    /// объединённая вниз: нормализация повторяет его в каждой строке, а на
    /// странице оно одно, над всем своим блоком. Начало, поставленное по
    /// нему, уходило бы выше куска — к строкам, которых в нём нет. Такие
    /// значения опорой служат, только если своих у строк нет вовсе.
    static func anchorRows(of chunk: String, ignoringHyphens: Bool) -> [[String]] {
        let rows = tableRows(of: chunk).map { row -> [String] in
            var cells: [String] = []
            for cell in row {
                let normalised = NormalisedText.normalise(cell, ignoringHyphens: ignoringHyphens)
                if normalised.count >= minimumCellLength, !cells.contains(normalised) { cells.append(normalised) }
            }
            return cells
        }
        var rowsHolding: [String: Int] = [:]
        for row in rows { for cell in row { rowsHolding[cell, default: 0] += 1 } }
        let own = rows.map { row in row.filter { rowsHolding[$0] == 1 } }
        return (own.contains { !$0.isEmpty } ? own : rows).filter { !$0.isEmpty }
    }

    /// Ячейка на странице целиком, а не внутри длинного слова — тем же
    /// правилом, что и части (`wholeOccurrences`).
    static func wholeCell(
        _ needle: String, in haystack: NormalisedText, searching text: NSString, after start: String.Index?
    ) -> Range<String.Index>? {
        let from = start.map { haystack.value.utf16.distance(from: haystack.value.startIndex, to: $0) } ?? 0
        guard let found = wholeOccurrences(of: needle, in: text, from: from, limit: 1).first else { return nil }
        return Range(found, in: haystack.value)
    }

    /// Строки данных Markdown-таблиц куска: без строки «| --- |» и без шапки
    /// над ней. Разбор — тот же, что у нарезки (`TableText`): экранированная
    /// `\|` внутри значения остаётся в нём.
    static func tableRows(of chunk: String) -> [[String]] {
        let lines = chunk.components(separatedBy: "\n")
        var rows: [[String]] = []
        for (index, line) in lines.enumerated() where TableText.isRow(line) {
            if TableText.isSeparator(line) { continue }
            if index + 1 < lines.count, TableText.isSeparator(lines[index + 1]) { continue }
            rows.append(TableText.cells(of: line))
        }
        return rows
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
        guard var headRange = haystack.normalisedRange(of: head) else { return nil }
        guard let tailRange = haystack.normalisedRange(of: tail, after: headRange.upperBound)
        else { return nil }
        // Начало — ближайшее к концу: первое попавшееся бывает в
        // оглавлении или в таком же абзаце раздела выше, и подсветка
        // тянулась оттуда через сотни страниц.
        while let later = haystack.normalisedRange(of: head, after: haystack.value.index(after: headRange.lowerBound)),
              later.upperBound <= tailRange.lowerBound {
            headRange = later
        }
        // И всё равно не шире куска втрое: иначе это конец чужого места.
        let spread = haystack.value.distance(from: headRange.lowerBound, to: tailRange.upperBound)
        guard spread <= needle.count * maximumSpread else { return nil }
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
