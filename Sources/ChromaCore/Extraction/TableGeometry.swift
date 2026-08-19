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
                } else if let previous, Double(word.box.minX - previous.maxX) > space {
                    // Обычный пробел между словами: у знаков его в тексте нет,
                    // потому что пробелы отброшены вместе с прочими пустыми.
                    current.append(" ")
                }
                current.append(word.text)
                end = Double(word.box.maxX)
                previous = word.box
            }
            cells.append(Cell(minX: start, maxX: end, text: current.trimmingCharacters(in: .whitespaces)))
            let filled = cells.filter { !$0.text.isEmpty }
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
    /// Замер на смете заказчика: «31 585 738,00» приходило как
    /// «31 585 738 00», номер позиции «11.1» — как «11 1», а строка таблицы
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

    // MARK: - Строки в таблицу

    /// Страница, собранная по координатам. `nil` — таблиц на ней нет,
    /// и тогда всё остаётся как было.
    ///
    /// Признак таблицы — не «в строке есть широкий промежуток»: такие
    /// промежутки даёт и обычный текст с выключкой по формату, и абзацный
    /// отступ, и номер страницы в углу. Признак — **повторяемость отступа**:
    /// три и более строки подряд, у которых ячейки начинаются на одних и тех же
    /// отступах. Без этого условия таблицей объявлялись три страницы из четырёх.
    static func text(of lines: [Line]) -> String? { assess(lines).text }

    /// То же, но со вторым ответом: **была ли на странице таблица**, которую
    /// собрать не удалось.
    ///
    /// Разница важна для того, кто потом читает текст. «Таблиц нет» и
    /// «таблица есть, но осталась сеткой чисел без названий колонок» — это
    /// для агента, считающего смету, совершенно разные страницы, а в тексте
    /// они выглядят одинаково. Живой случай: из семи страниц собрались три,
    /// остальные ушли плоским текстом, и по ним посчитали смету.
    static func assess(_ lines: [Line]) -> (text: String?, unassembledTable: Bool) {
        guard !lines.isEmpty else { return (nil, false) }
        let tolerance = max(minimumColumnGap, (lines.first?.height ?? 10) * columnGapRatio)
        let columns = supportedColumns(in: lines, tolerance: tolerance)
        guard columns.count >= 2 else { return (nil, false) }

        func columnIndexes(of line: Line) -> Set<Int> {
            Set(line.cells.compactMap { cell in
                columns.firstIndex { abs($0 - cell.minX) <= tolerance }
            })
        }

        var blocks: [String] = []
        var table: [Line] = []
        var found = 0
        /// Строки, стоявшие по колонкам, но в таблицу не сложившиеся.
        var refused = 0

        func flush() {
            defer { table = [] }
            let grid = table.count >= minimumRows ? aligned(table) : []
            guard let width = grid.first?.count, width > 1, width <= maximumColumns,
                  looksLikeTable(grid)
            else {
                if table.count >= minimumRows { refused += table.count }
                blocks.append(contentsOf: table.map(\.text).filter { !$0.isEmpty })
                return
            }
            found += grid.count
            blocks.append(TableText.render(grid))
        }

        for line in lines {
            if columnIndexes(of: line).count >= 2 {
                table.append(line)
                continue
            }
            flush()
            let text = line.text
            if !text.isEmpty { blocks.append(text) }
        }
        flush()

        // Страница не сложилась в таблицу. Но если табличные строки на ней
        // были — а их набралось на целую таблицу, — молчать об этом нельзя:
        // текст уйдёт к агенту сеткой чисел без названий колонок.
        guard found >= minimumRows, Double(found) / Double(lines.count) >= tableShare else {
            return (nil, refused + found >= minimumRows)
        }
        let text = blocks.joined(separator: "\n\n")
        // Часть страницы собралась, часть — нет: та часть тоже уйдёт плоской.
        return (text.isEmpty ? nil : text, refused >= minimumRows)
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
