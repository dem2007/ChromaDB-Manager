import Foundation
import CoreGraphics

/// Сборка таблицы по координатам — общая для всего, что знает, **где** на
/// странице стоит текст.
///
/// Родилась из разбора PDF, но к PDF не привязана: те же правила работают
/// для распознанного скана, где координаты даёт Vision. Это и есть причина
/// вынести её отдельно — иначе у одного и того же разбора появилось бы два
/// подобия, и расходиться они начали бы с первой же правки.
///
/// **Что здесь не делается.** Не разбираются линии разметки (их может
/// не быть вовсе), объединённые ячейки и перенос внутри ячейки на несколько
/// строк: такая ячейка станет несколькими строками таблицы. Это осознанный
/// предел — см. 11.2.1.
enum TableGeometry {
    /// Кусок текста и его место на странице.
    ///
    /// Для PDF это **знак** (координаты есть у каждого), для распознанного
    /// скана — слово (мельче Vision не отдаёт). Разница снимается порогом
    /// пробела: между знаками одного слова промежутка нет, между словами есть.
    struct Word {
        var box: CGRect
        var text: String
        /// Перед знаком в тексте страницы стоит пробел. Граница слова
        /// по тексту, а не по промежутку: в ужатой ячейке пробел шириной
        /// 0,2 пункта, и по промежутку «Наименование характеристики»
        /// склеивалось в одно слово.
        var spaceBefore = false
    }

    /// Одна ячейка: где стоит и что в ней.
    struct Cell {
        var minX: Double
        var maxX: Double
        var text: String
    }

    /// Строка страницы — набор ячеек на одной высоте.
    struct Line {
        var y: Double
        var height: Double
        var cells: [Cell]

        var text: String {
            cells.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Пороги

    /// Промежуток шире этой доли от роста знака — граница колонки.
    ///
    /// Межбуквенный промежуток на порядок меньше: замер на настоящей странице
    /// даёт медиану 0 и 95-й процентиль около 4 пунктов при кегле 10.
    static let columnGapRatio = 0.9
    /// И не уже этого, каким бы мелким ни был шрифт.
    static let minimumColumnGap = 5.0
    /// Промежуток шире этой доли от роста знака — пробел между словами.
    ///
    /// Считается от роста знака, а не от ширины предыдущего: у «i» ширина
    /// полтора пункта, и любой кернинг после неё выглядел бы пробелом,
    /// а после «Ш» настоящий пробел терялся. Замер на 87 табличных страницах
    /// корпуса до правки: 152 слова разорвано лишним пробелом, 38 склеены;
    /// после — 143 и 10.
    static let wordGapRatio = 0.22
    /// Соседние по высоте знаки, расходящиеся меньше чем на столько от роста
    /// знака, — одна строка.
    static let lineTolerance = 0.45
    /// Знак ниже этой доли от роста строки — знак препинания, а не буква
    ///. Точка занимает пятую часть роста цифры, запятая — треть;
    /// самая низкая буква, «о» строчная, — больше половины.
    static let lowGlyphRatio = 0.6
    /// Насколько базовая линия такого знака может отходить от базовой линии
    /// строки — в ростах знака. Замер на живой странице: у точки расхождение
    /// 0.13 пункта при росте 5.4, у запятой — 1.28 (она свисает ниже).
    static let lowGlyphBaseline = 0.4
    /// Колонок больше этого — это не таблица, а разлетевшийся текст.
    static let maximumColumns = 24
    /// Строк таблицы меньше этого — не таблица, а две строки с отступом.
    static let minimumRows = 3
    /// Доля строк с колонками, ниже которой страница считается обычным текстом.
    static let tableShare = 0.35
    /// Доля занятых клеток, ниже которой это не таблица, а дырявая сетка
    /// из случайно совпавших отступов.
    static let filledShare = 0.55

    // MARK: - Куски текста в строки

    /// Строки страницы: по вертикали — цепочкой, по горизонтали — по промежуткам.
    ///
    /// Строки собираются **цепочкой**, а не сравнением с первым знаком: рамка
    /// знака тесная, у «А» она от базовой линии вверх, у «р» уходит вниз
    /// выносным элементом, у «о» кончается на высоте строчных. Ни низ,
    /// ни середина, ни верх по отдельности не держатся — по любому из них
    /// строка рассыпается, и «Артикул» приходит как «А тик л». Зато соседние
    /// по высоте знаки одной строки расходятся на доли пункта.
    /// - Parameter separated: куски уже являются **словами** — тогда пробел
    ///   между ними ставится всегда. Так отдаёт распознавание: границы слов
    ///   оно знает точно, и угадывать их по промежутку значит терять пробелы
    ///   там, где их и так видно (замер на скане: слова слипались в одно).
    static func lines(from words: [Word], height: Double, separated: Bool = false) -> [Line] {
        guard height > 0, !words.isEmpty else { return [] }

        var grouped: [[Word]] = []
        var previousY: Double?
        for word in words.sorted(by: { $0.box.midY > $1.box.midY }) {
            let y = Double(word.box.midY)
            if let previousY, abs(previousY - y) <= height * lineTolerance, !grouped.isEmpty {
                grouped[grouped.count - 1].append(word)
            } else {
                grouped.append([word])
            }
            previousY = y
        }
        let byLine = returningPunctuation(grouped, height: height)

        let gap = max(minimumColumnGap, height * columnGapRatio)
        let space = max(0.8, height * wordGapRatio)
        var result: [Line] = []
        for line in byLine {
            let sorted = line.sorted { $0.box.minX < $1.box.minX }
            var cells: [Cell] = []
            var current = ""
            var start = Double(sorted[0].box.minX)
            var end = Double(sorted[0].box.maxX)
            var previous: CGRect?
            for word in sorted {
                if let previous, Double(word.box.minX - previous.maxX) > gap {
                    cells.append(Cell(minX: start, maxX: end, text: current.trimmingCharacters(in: .whitespaces)))
                    current = ""
                    start = Double(word.box.minX)
                } else if previous != nil, separated {
                    current.append(" ")
                } else if let previous,
                          Double(word.box.minX - previous.maxX) > space || word.spaceBefore {
                    // Пробел между словами. Сами пробелы как куски не идут —
                    // у них нет начертания, — поэтому он ставится по промежутку
                    // или по пробелу документа перед знаком: в ужатой
                    // ячейке промежутка не видно, а пробел в тексте есть.
                    current.append(" ")
                }
                current.append(word.text)
                end = Double(word.box.maxX)
                previous = word.box
            }
            cells.append(Cell(minX: start, maxX: end, text: current.trimmingCharacters(in: .whitespaces)))
            let filled = joiningJustified(cells.filter { !$0.text.isEmpty })
            guard !filled.isEmpty else { continue }
            result.append(Line(y: Double(sorted[0].box.midY), height: height, cells: filled))
        }
        return result
    }

    /// Возвращает знаки препинания в их строку.
    ///
    /// **Что было.** Строки собираются по середине рамки знака, а у точки она
    /// лежит на три пункта ниже, чем у стоящей рядом цифры: рамка точки —
    /// один пункт от базовой линии, рамка цифры — семь. При допуске в 2,4
    /// пункта точка не дотягивалась до своей строки и уходила в соседнюю.
    /// Замер на смете заказчика: «12 345 678,00» приходило как
    /// «12 345 678 00», номер позиции «11.1» — как «11 1», а строка таблицы
    /// рассыпалась на три и утягивала за собой всю страницу в плоский текст.
    ///
    /// **Почему пост-обработкой.** Разбиение остальных знаков не трогается
    /// вовсе: цепочка по середине рамки работает для букв и цифр, и менять
    /// её ради точки значило бы чинить одно, ломая другое (проверено —
    /// сборка обычных таблиц разъезжалась).
    ///
    /// Правда — в базовой линии: у цифры и у точки она общая до сотых долей.
    /// Поэтому низкий знак переносится в ту строку, чья базовая линия к нему
    /// ближе, — и только если она ближе, чем у строки, где он оказался.
    static func returningPunctuation(_ lines: [[Word]], height: Double) -> [[Word]] {
        guard lines.count > 1, height > 0 else { return lines }

        func isLow(_ word: Word) -> Bool { Double(word.box.height) < height * lowGlyphRatio }
        /// Базовая линия строки — по её высоким знакам. Низкие в расчёт не
        /// идут: у запятой низ рамки под строкой, и она сдвинула бы отсчёт.
        func baseline(_ line: [Word]) -> Double? {
            let tall = line.filter { !isLow($0) }.map { Double($0.box.minY) }.sorted()
            return tall.isEmpty ? nil : tall[tall.count / 2]
        }

        let baselines = lines.map(baseline)
        var result = lines.map { $0.filter { !isLow($0) } }

        for (index, line) in lines.enumerated() {
            for word in line where isLow(word) {
                let low = Double(word.box.minY)
                var best = index
                var distance = baselines[index].map { abs(low - $0) } ?? .greatestFiniteMagnitude
                for (candidate, value) in baselines.enumerated() {
                    guard let value, abs(low - value) < distance else { continue }
                    distance = abs(low - value)
                    best = candidate
                }
                // Слишком далеко от любой базовой линии — знак остаётся там,
                // где был: выдумывать ему строку хуже, чем оставить как есть.
                result[distance <= height * lowGlyphBaseline ? best : index].append(word)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// Строка, выровненная по ширине, — одна ячейка, а не столько, сколько
    /// в ней слов.
    ///
    /// **Что было.** Порог «граница колонки» считается от роста знака,
    /// а рост — по строчным буквам: у кегля 12 это 5,2 пункта, и граница
    /// выходила в 5 пунктов. Выключка по формату растягивает пробелы до 5–11
    /// пунктов, и каждая растянутая строка договора резалась по словам. Слов
    /// на странице много, начала их случайно совпадают по вертикали — и
    /// страница текста уходила в базу таблицей в десять колонок, без сшивки
    /// абзацев. Замер на 58 PDF корпуса: 159 «табличных» страниц, из них
    /// 12 — обычный текст, и 447 ложных оговорок «таблица не собрана».
    ///
    /// **Признак — ровность промежутков.** Выключка растягивает все пробелы
    /// строки одинаково; между колонками таблицы промежутки разные, потому
    /// что разной длины значения. Строка от четырёх ячеек, где хотя бы три
    /// промежутка и семь десятых всех почти равны медиане, а в ячейках
    /// буквы, — это текст: ровные промежутки склеиваются, заметно более
    /// широкий (номер пункта с табуляцией) остаётся границей. Числовая
    /// строка таблицы букв не содержит и под правило не попадает.
    static func joiningJustified(_ cells: [Cell]) -> [Cell] {
        guard cells.count >= 4 else { return cells }
        var gaps: [Double] = []
        for index in 1..<cells.count { gaps.append(cells[index].minX - cells[index - 1].maxX) }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let band = max(1.5, median * 0.2)
        let even = gaps.filter { abs($0 - median) <= band }.count
        guard even >= 3, Double(even) >= Double(gaps.count) * 0.7 else { return cells }
        let wordy = cells.filter { $0.text.contains { $0.isLetter } }.count
        guard Double(wordy) >= Double(cells.count) * 0.6 else { return cells }
        var result = [cells[0]]
        for index in 1..<cells.count {
            if gaps[index - 1] <= median + band {
                result[result.count - 1].maxX = cells[index].maxX
                result[result.count - 1].text += " " + cells[index].text
            } else {
                result.append(cells[index])
            }
        }
        return result
    }

    // MARK: - Строки в таблицу

    /// Кусок страницы: таблица в Markdown или строки обычного текста.
    ///
    /// Строки текста отдаются как есть, а сшиваются в абзацы потом — тем,
    /// у кого есть словарь документа для дефисов. Раньше каждая
    /// строка текста на «табличной» странице становилась своим абзацем,
    /// и предложение, перенесённое на две строки, рвалось пустой строкой.
    enum PageBlock: Equatable {
        /// Строки таблицы, первая — шапка. `edges` — границы колонок
        /// таблицы по рамке: по ним таблица, продолженная на следующей
        /// странице, узнаётся как та же самая.
        case table(rows: [[String]], edges: [Double]?)
        case text([String])
    }

    /// Страница, собранная по координатам. `nil` — таблиц на ней нет,
    /// и тогда всё остаётся как было.
    ///
    /// Признак таблицы — не «в строке есть широкий промежуток»: такие
    /// промежутки даёт и обычный текст с выключкой по формату, и абзацный
    /// отступ, и номер страницы в углу. Признак — **повторяемость отступа**:
    /// три и более строки подряд, у которых ячейки начинаются на одних и тех же
    /// отступах. Без этого условия таблицей объявлялись три страницы из четырёх.
    static func text(of lines: [Line]) -> String? {
        assess(lines).blocks.map { render($0, vocabulary: .empty) }
    }

    /// Блоки — в текст: таблицы как есть, строки текста — сшитыми.
    static func render(_ blocks: [PageBlock], vocabulary: PDFTextReflow.Vocabulary) -> String {
        blocks.map { block -> String in
            switch block {
            // Записи сводятся здесь, при выводе: к этому времени таблица,
            // продолженная со страницы на страницу, уже получила шапку
            // и все свои строки.
            case .table(let rows, _): return TableText.render(TableRecords.merged(rows))
            case .text(let lines): return PDFTextReflow.page(lines.joined(separator: "\n"), vocabulary: vocabulary)
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// То же, но со вторым ответом: **была ли на странице таблица**, которую
    /// собрать не удалось.
    ///
    /// Разница важна для того, кто потом читает текст. «Таблиц нет» и
    /// «таблица есть, но осталась сеткой чисел без названий колонок» — это
    /// для агента, считающего смету, совершенно разные страницы, а в тексте
    /// они выглядят одинаково. Живой случай: из семи страниц собрались три,
    /// остальные ушли плоским текстом, и по ним посчитали смету.
    static func assess(_ lines: [Line], separated: Bool = false) -> (blocks: [PageBlock]?, unassembledTable: Bool) {
        guard !lines.isEmpty else { return (nil, false) }
        let tolerance = max(minimumColumnGap, (lines.first?.height ?? 10) * columnGapRatio)
        let columns = supportedColumns(in: lines, tolerance: tolerance)
        guard columns.count >= 2 else { return (nil, false) }

        func columnIndexes(of line: Line) -> Set<Int> {
            Set(line.cells.compactMap { cell in
                columns.firstIndex { abs($0 - cell.minX) <= tolerance }
            })
        }
        let indexes = lines.map(columnIndexes)

        var blocks: [PageBlock] = []
        var prose: [String] = []
        var table: [Line] = []
        var found = 0
        /// Строки, стоявшие по колонкам, но в таблицу не сложившиеся.
        var refused = 0

        func text(_ line: String) {
            guard !line.isEmpty else { return }
            prose.append(line)
        }
        func closeProse() {
            if !prose.isEmpty { blocks.append(.text(prose)) }
            prose = []
        }
        func flush() {
            defer { table = [] }
            // Нумерованные пункты с номером на табуляции («1.1.1.» и текст
            // пункта) встают по двум отступам, как колонки. Это список,
            // а не таблица: он идёт текстом и несобранной таблицей
            // не считается — иначе оговорка «таблица осталась плоским
            // текстом» стояла на каждой странице договора.
            // Между пунктами бывают строки текста, случайно вставшие в две
            // «ячейки», поэтому — по большинству.
            let split = table.filter { $0.cells.count >= 2 }
            let numbered = split.filter(isNumberedItem).count
            if numbered > 0, numbered * 2 >= split.count {
                table.map(\.text).forEach(text)
                return
            }
            let grid = table.count >= minimumRows ? aligned(table) : []
            // Схема со скана — не таблица, и не «несобранная таблица» тоже:
            // оговорка про числа, на которые нельзя опираться, о ней ложна.
            if separated, isSplitAcrossRows(grid) {
                table.map(\.text).forEach(text)
                return
            }
            guard let width = grid.first?.count, width > 1, width <= maximumColumns,
                  looksLikeTable(grid)
            else {
                // Несобранной таблицей считается та, где есть числа: оговорка
                // говорит «на числа оттуда опираться нельзя», и для подписей
                // сторон в две колонки или строк с прочерками она ложна
                //. Замер на договоре: 41 страница с оговоркой, из них
                // с числами — меньше половины.
                let cells = table.flatMap(\.cells)
                let numeric = cells.filter { $0.text.contains(where: \.isNumber) }.count
                if table.count >= minimumRows, numeric * 3 >= cells.count { refused += table.count }
                table.map(\.text).forEach(text)
                return
            }
            found += grid.count
            closeProse()
            blocks.append(.table(rows: grid, edges: nil))
        }

        for (index, line) in lines.enumerated() {
            if indexes[index].count >= 2 {
                table.append(line)
                continue
            }
            // Перенос внутри ячейки: строка из одной ячейки, стоящая
            // ровно в колонке таблицы, — продолжение длинного значения, если
            // таблица уже идёт и продолжается следом. Раньше такая строка
            // рвала таблицу, и страница прайса, где у каждой позиции название
            // в две строки, уходила плоским текстом — цены отдельно от
            // позиций. Строка не в первой колонке — перенос наверняка: так
            // текст абзаца не начинается.
            if !table.isEmpty, line.cells.count == 1, let only = indexes[index].first {
                let resumes = lines.indices.dropFirst(index + 1).prefix(2).contains { indexes[$0].count >= 2 }
                if only > 0 || resumes {
                    table.append(line)
                    continue
                }
            }
            flush()
            text(line.text)
        }
        flush()
        closeProse()

        // Страница не сложилась в таблицу. Но если табличные строки на ней
        // были — а их набралось на целую таблицу, — молчать об этом нельзя:
        // текст уйдёт к агенту сеткой чисел без названий колонок.
        //
        // Таблица на малой доле страницы уходит текстом: так подписи блоков
        // на схеме и маркированные списки не становятся «таблицами». Но
        // оговорки «не собрана» она больше не даёт: собраться она
        // собралась, а страница просто не табличная. Оговорку дают только
        // несобранные строки с числами.
        guard found >= minimumRows, Double(found) / Double(lines.count) >= tableShare else {
            return (nil, refused >= minimumRows)
        }
        // Часть страницы собралась, часть — нет: та часть тоже уйдёт плоской.
        return (blocks, refused >= minimumRows)
    }

    /// Страница с таблицами по рамке и текстом вокруг.
    ///
    /// Таблицы по рамке собираются первыми и забирают свой текст; остальной
    /// текст идёт по порядку сверху вниз, кусками между таблицами, и каждый
    /// кусок ещё проверяется на таблицу без рамки. Без рамки на странице —
    /// всё как раньше.
    /// Подпись колонки длиннее этого — не подпись: так выглядит схема,
    /// рамки которой сложились в сетку.
    static let maximumHeaderCell = 300

    /// Сетка — схема, а не таблица: в первой строке ячейка длиннее подписи.
    static func isDiagram(_ rows: [[String]]) -> Bool {
        rows.first?.contains { $0.count > maximumHeaderCell } ?? false
    }

    /// Сколько пар «ячейка над ячейкой» нужно, чтобы судить о разрывах:
    /// у таблицы в две строки одна оборванная подпись — ещё не схема.
    static let minimumSplitPairs = 3
    /// Доля пар-продолжений, начиная с которой сетка — схема.
    static let splitShare = 0.3

    /// Текст ячеек разорван по строкам сетки: ячейка кончается переносом
    /// («Предостав-»), а под ней — продолжение со строчной буквы («ление
    /// АРІ-ин-», «терфейсов»).
    ///
    /// **Схема, а не таблица.** На распознанной схеме рамки блоков
    /// складываются в сетку, но блоки не стоят рядами, и строки сетки режут
    /// их поперёк: подпись блока в три строки уходит в три строки таблицы,
    /// в соседние колонки — обрывки соседних блоков («(F», «Эле», «пре»).
    /// У настоящей таблицы с рамкой многострочное значение остаётся
    /// в одной ячейке — сетку там рисует сама рамка ячейки.
    ///
    /// Сетка с колонкой чисел — таблица, даже с разрывами: у прайса со скана
    /// распознавание срезает заглавные («програминое обеспечение #6.1»),
    /// и строки начинаются со строчной, но количество и цены стоят своей
    /// колонкой. В блоках схемы чистых чисел нет.
    ///
    /// Замер на корпусе (сканы): из 149 «таблиц» со схем архитектуры
    /// отбраковано 122; из 31 настоящей распознанной таблицы (прайсы,
    /// спецификации) — ни одной. На векторных PDF и Word признак не годится:
    /// там ячейка законно начинается со строчной («шт.», «да», «в т. ч.»), —
    /// и проверяется он только у сканов.
    static func isSplitAcrossRows(_ rows: [[String]]) -> Bool {
        guard !hasNumericColumn(rows) else { return false }
        var pairs = 0
        var continued = 0
        for (upper, lower) in zip(rows, rows.dropFirst()) {
            for (above, below) in zip(upper, lower) where !above.isEmpty && !below.isEmpty && above != below {
                pairs += 1
                if above.hasSuffix("-") || (below.first.map { $0.isLetter && $0.isLowercase } ?? false) {
                    continued += 1
                }
            }
        }
        return pairs >= minimumSplitPairs && Double(continued) >= Double(pairs) * splitShare
    }

    /// Есть ли колонка, где не меньше половины значений — числа («1»,
    /// «2 345 678,00»), и таких значений хотя бы три.
    static func hasNumericColumn(_ rows: [[String]]) -> Bool {
        let width = rows.map(\.count).max() ?? 0
        return (0..<width).contains { column in
            let values = rows.compactMap { column < $0.count && !$0[column].isEmpty ? $0[column] : nil }
            let numbers = values.filter { value in
                value.contains(where: \.isNumber)
                    && value.allSatisfy { $0.isNumber || $0 == " " || $0 == "." || $0 == "," || $0 == "\u{00A0}" }
            }
            return numbers.count >= 3 && numbers.count * 2 >= values.count
        }
    }

    static func page(
        words: [Word], grids: [TableLattice.Grid], height: Double, separated: Bool = false
    ) -> (blocks: [PageBlock]?, unassembledTable: Bool) {
        var tables: [(top: Double, block: PageBlock)] = []
        var used: Set<Int> = []
        for grid in grids {
            guard let (spanned, taken) = TableLattice.table(grid, words: words, height: height, separated: separated)
            else { continue }
            // Название таблицы первой строкой внутри рамки — строкой текста
            // над таблицей.
            let (caption, table) = spanned.separatingCaption()
            let rows = table.rows(mergingRecords: false)
            guard rows.count >= 1 else { continue }
            // Схема со скана: рамки блоков сложились в сетку, а её
            // строки режут блоки поперёк. Сетку не берём совсем — слова
            // остаются строками текста страницы, в своём порядке.
            if separated, isSplitAcrossRows(rows) { continue }
            // Схема-рисунок, а не таблица: рамки блоков на схеме
            // складываются в сетку, и в «шапку» уходит распознанный текст
            // целого блока — 1666 знаков в одной ячейке. Подпись колонки
            // такой не бывает. Текст схемы остаётся, но строками: шапка
            // из него, дописанная к каждому куску, раздувала бы их вдвое.
            if isDiagram(rows) {
                // Блок, объединённый вниз, нормализация повторила в каждой
                // строке; у схемы строк нет, и повтор — просто дубль.
                var seen: Set<String> = []
                let text = ([caption].compactMap { $0 } + rows.flatMap { $0 })
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                tables.append((grid.ys[0], .text(text)))
                used.formUnion(taken)
                continue
            }
            if let caption { tables.append((grid.ys[0] + 0.001, .text([caption]))) }
            tables.append((grid.ys[0], .table(rows: rows, edges: grid.xs)))
            used.formUnion(taken)
        }
        let outside = words.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        let lines = lines(from: outside, height: height, separated: separated)
        guard !tables.isEmpty else { return assess(lines, separated: separated) }

        var blocks: [PageBlock] = []
        var unassembled = false
        var run: [Line] = []
        func closeRun() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let assessed = assess(run, separated: separated)
            if let found = assessed.blocks {
                blocks += found
                unassembled = unassembled || assessed.unassembledTable
            } else {
                blocks.append(.text(run.map(\.text).filter { !$0.isEmpty }))
                unassembled = unassembled || assessed.unassembledTable
            }
        }
        var pending = tables.sorted { $0.top > $1.top }
        for line in lines {
            while let next = pending.first, next.top >= line.y {
                closeRun()
                blocks.append(next.block)
                pending.removeFirst()
            }
            run.append(line)
        }
        closeRun()
        blocks += pending.map(\.block)
        return (blocks, unassembled)
    }

    /// Строка — пункт с номером: номер отдельной ячейкой, за ним текст.
    static func isNumberedItem(_ line: Line) -> Bool {
        guard line.cells.count == 2, let first = line.cells.first?.text, first.count <= 12 else { return false }
        return PDFTextReflow.startsWithListMarker(first + " x")
    }

    /// Отступы, на которых начинаются ячейки **нескольких** строк.
    ///
    /// Одиночный широкий промежуток бывает у любой строки; колонка — это
    /// отступ, который повторяется.
    static func supportedColumns(in lines: [Line], tolerance: Double) -> [Double] {
        var starts: [Double] = []
        for line in lines {
            for cell in line.cells { starts.append(cell.minX) }
        }
        starts.sort()

        var result: [Double] = []
        var index = 0
        while index < starts.count {
            var end = index
            while end + 1 < starts.count, starts[end + 1] - starts[index] <= tolerance { end += 1 }
            if end - index + 1 >= minimumRows { result.append(starts[index]) }
            index = end + 1
        }
        return result
    }

    /// Ячейки строк — по общим колонкам.
    ///
    /// Без этого строка, где ячейка пуста, съезжает влево: у соседних строк
    /// три ячейки, у неё две, и значение второй колонки встаёт в первую.
    static func aligned(_ lines: [Line]) -> [[String]] {
        let tolerance = max(minimumColumnGap, (lines.first?.height ?? 10) * columnGapRatio)
        var starts: [Double] = []
        for line in lines {
            for cell in line.cells { starts.append(cell.minX) }
        }
        starts.sort()

        // Колонка — это отступ, на котором что-то стоит у **половины** строк
        // блока. Отступ, встретившийся однажды, колонкой не считается: иначе
        // обычный текст с разной длиной строк даёт дюжину колонок, в которых
        // заполнена одна клетка из десяти.
        let support = max(2, lines.count / 2)
        var columns: [Double] = []
        var index = 0
        while index < starts.count {
            var end = index
            while end + 1 < starts.count, starts[end + 1] - starts[index] <= tolerance { end += 1 }
            if end - index + 1 >= support { columns.append(starts[index]) }
            index = end + 1
        }
        guard columns.count > 1, columns.count <= maximumColumns else {
            return lines.map { $0.cells.map(\.text) }
        }

        var grid: [[String]] = []
        for line in lines {
            var row = Array(repeating: "", count: columns.count)
            for cell in line.cells {
                // Ближайшая колонка слева: ячейка начинается на её отступе
                // или правее — например, число, выровненное по правому краю.
                var index = 0
                for (position, column) in columns.enumerated() where cell.minX >= column - tolerance {
                    index = position
                }
                row[index] = row[index].isEmpty ? cell.text : row[index] + " " + cell.text
            }
            grid.append(row)
        }
        return grid
    }

    /// Похоже ли собранное на таблицу, а не на текст в две колонки.
    static func looksLikeTable(_ grid: [[String]]) -> Bool {
        guard let width = grid.first?.count, width > 1 else { return false }
        let cells = grid.flatMap { $0 }
        let filled = cells.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return false }

        // Заполненность — главный признак. У настоящей таблицы клетки заняты;
        // у обычного текста слова попадают на случайные отступы, и «таблица»
        // из них выходит дырявой: восемнадцать колонок, три слова в строке.
        guard Double(filled.count) / Double(cells.count) >= filledShare else { return false }

        // И длина ячейки: у таблицы это значение — артикул, число, короткое
        // название, — у текста в две колонки это строка прозы.
        let lengths = filled.map(\.count).sorted()
        let median = lengths[lengths.count / 2]
        // У двух колонок порог строже: там, где колонок три и больше, длинная
        // ячейка — это описание в таблице, а у двух длинны обе колонки только
        // у текста, свёрстанного в две колонки. Проверено на скане, который
        // выглядел таблицей: медианы колонок 86 и 128 — это проза, и отказ
        // здесь правильный.
        return width >= 3 ? median <= 120 : median <= 60
    }

    /// Рост знака, по которому считаются все пороги: медиана, а не среднее —
    /// одна крупная надпись не должна двигать порог для всей страницы.
    ///
    /// Считается **по буквам и цифрам**, а не по всем знакам подряд.
    /// Рамка точки — пятая часть рамки буквы, и страница, где точек больше,
    /// чем букв, отдавала медиану в четыре раза меньше настоящего кегля.
    /// Живой случай: оглавление на 90 строк, каждая с отточием до номера
    /// страницы, — 5209 точек против 803 букв, медиана 1,2 пункта при кегле
    /// 11. От этого рассыпалось всё сразу: допуск строки становился меньше
    /// полупункта, и «Содержание» приходило как «С о е жание д р» — буквы
    /// одного слова оказывались в разных строках и разных колонках, а
    /// страница уходила в базу markdown-таблицей из слогов.
    ///
    /// Буквы отбираются **по самому знаку**, а не по его росту. Отбор
    /// «выше такой-то доли от верхнего процентиля» разбирался и отвергнут:
    /// на странице со смешанным кеглем — титуле, слайде, первой полосе —
    /// крупный набор поднимает процентиль, и порог отсекает уже основной
    /// текст. Проба на 100 знаках: 30 заголовочных ростом 12 пунктов и
    /// 70 текстовых ростом 5 давали медиану 12 вместо 5, то есть вдвое
    /// завышенные пороги для всей страницы. Признак «это буква» от
    /// распределения кеглей не зависит вовсе.
    ///
    /// Замер на корпусе заказчика (120 файлов): собранных таблиц 265 против
    /// 263 у отбора по процентилю, рассыпавшихся страниц 3 и 3 — то есть
    /// правило не хуже там, где оба работают, и не ломается там, где то
    /// другое ломается.
    static func medianHeight(of words: [Word]) -> Double {
        let letters = words
            .filter { $0.text.contains { $0.isLetter || $0.isNumber } }
            .map { Double($0.box.height) }
            .sorted()
        guard !letters.isEmpty else {
            // Страница без единой буквы: чертёж, ведомость из одних знаков
            // препинания. Мерить нечем, кроме того, что есть.
            let heights = words.map { Double($0.box.height) }.sorted()
            return heights.isEmpty ? 0 : heights[heights.count / 2]
        }
        return letters[letters.count / 2]
    }
}
