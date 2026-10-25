import Foundation

/// Таблица с объединёнными ячейками — один вид и одно правило на все
/// форматы.
///
/// **Зачем.** Строка таблицы уходит в базу и читается агентом сама по себе:
/// кусок длинной таблицы — это шапка и несколько строк из середины. Значение,
/// объединённое на восемь строк, стоит в файле **один** раз, в верхней из них,
/// и семь остальных строк приходили в базу без него. В смете это значит
/// позицию без раздела, сервер без площадки, цену без условия. Правило
/// простое: **в каждой строке — всё, что к ней относится**.
///
/// Каждый формат описывает свою таблицу одинаково — якорными ячейками
/// с размахом по строкам и колонкам, — а дальше одна и та же нормализация:
///
/// 1. **Объединение вниз** — значение повторяется в каждой строке размаха.
///    Это не выдумка: объединив ячейку, автор и сказал, что она общая.
/// Пустая необъединённая ячейка остаётся пустой.
/// 2. **Объединение вбок** — значение тоже в каждой колонке размаха
///: объединённая клетка общая для всех колонок, которые она
///    накрывает, и строка, разрезанная на куски, или колонка, прочитанная
///    отдельно, не должны терять её значение. Там, где колонки вывода
///    собираются по шапке, одна и та же ячейка в группе не повторяется.
/// Ячейка во всю ширину таблицы пишется один раз: это подпись
///    группы строк, своей колонки у неё нет.
/// 3. **Многоуровневая шапка** склеивается в одну строку: колонка «код» под
///    общим «Единица измерения» получает имя «Единица измерения / код».
/// У Markdown шапка одна, и нарезка повторяет в кусках только её.
/// 4. **Строка-раздел** — одна ячейка на всю ширину («1. Модернизация… в
///    г. Энск, Этап 1») — становится колонкой «Раздел» у каждой своей
///    строки, а сама уходит. Иначе позиции 1.7–1.10 в отдельном куске
///    теряли площадку, к которой относятся.
public struct SpannedTable: Sendable, Equatable {
    /// Якорная ячейка: левая верхняя клетка объединения или обычная ячейка.
    public struct Cell: Sendable, Equatable {
        public var text: String
        public var row: Int
        public var column: Int
        public var rowSpan: Int
        public var columnSpan: Int

        public init(text: String, row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1) {
            self.text = text
            self.row = row
            self.column = column
            self.rowSpan = max(1, rowSpan)
            self.columnSpan = max(1, columnSpan)
        }
    }

    public var cells: [Cell]
    /// Сколько строк сверху — шапка, если формат это знает (`<thead>`,
    /// повторяемые строки Word). `nil` — догадаться по форме.
    public var headerRows: Int?

    public init(cells: [Cell], headerRows: Int? = nil) {
        self.cells = cells
        self.headerRows = headerRows
    }

    /// Шапка не глубже этого: строк шапки больше трёх в деловых таблицах
    /// не бывает, а ошибка в догадке съела бы данные.
    static let maximumHeaderRows = 3
    /// Ячейка рядом с разделом, которая не мешает ему быть разделом: номер
    /// «1.», «2)», «I».
    static let sectionNumberLength = 8

    /// Готовый Markdown; название таблицы, если оно стояло первой строкой
    /// внутри неё, — строкой над таблицей.
    public func rendered() -> String { renderedWithLayout().text }

    /// Текст таблицы и её вид — одним разбором: вид нужен тому же,
    /// кто пишет текст, и второй разбор ради него удваивал работу на каждом
    /// листе.
    public func renderedWithLayout() -> (text: String, layout: Layout) {
        let (caption, table) = separatingCaption()
        // Полосы формы — строками, полосы таблицы — сеткой. Таблица,
        // оставшаяся таблицей целиком, — той сеткой, которой мерилась её
        // расточительность: второй раз она не строится.
        let (parts, grid) = table.segmentation()
        let body = grid ?? parts.map { part in
            part.layout == .form
                ? part.table.formLines().joined(separator: "\n")
                : TableText.render(part.table.rows())
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        return (caption.map { $0 + "\n" + body } ?? body, Self.summary(of: parts))
    }

    // MARK: - Таблица или форма

    /// Что это за таблица: записи под подписанными колонками или вёрстка.
    ///
    /// **Зачем.** Бланк, печатная форма, страница, свёрстанная таблицей, —
    /// это сетка, у которой нет колонок: «Продавец» и «ПАО Телеком-Пример» стоят
    /// в ней рядом не потому, что это графы, а потому, что так легло на
    /// листе. Записанная сеткой, такая таблица раздувалась в сотни раз:
    /// печатная форма Минфина на 144 узких колонки, 13 тысяч знаков текста —
    /// 832 куска и 4 миллиона знаков, потому что значение, объединённое на
    /// пятьдесят колонок, повторялось пятьдесят раз, пустые
    /// клетки шли чертами, а первая строка бланка — «шапкой» в каждом куске.
    ///
    /// **Как решают другие**: браузеры давно делят
    /// HTML-таблицы на таблицы данных и вёрстки по признакам строения
    /// (ячейки-подписи, повторяющиеся строки), RAGFlow считает лист формой,
    /// когда в большинстве строк заполнено не больше трёх ячеек,
    /// SpreadsheetLLM и Docling пишут объединение один раз и не пишут пустых
    /// клеток вовсе.
    ///
    /// **Правило** — по порядку:
    ///
    /// 1. **Расточительна ли сетка?** Markdown длиннее текста ячеек больше
    ///    чем втрое — значит, его заняли пустые клетки и копии объединений
    ///    (то, что SpreadsheetLLM называет главными источниками лишних
    ///    токенов). Обычная таблица, даже с пустыми клетками, сюда не
    ///    попадает и не меняется вовсе.
    /// 2. **Где в ней настоящие таблицы?** Шапка — строка узких подписей
    ///    (каждая не шире трёх колонок; год — тоже подпись), под которой
    ///    подряд идут строки, начинающие значения в её колонках. Шапка с
    ///    записями — таблица, всё вокруг неё — форма (`segments`). Так
    ///    остаются таблицами и редкие, но настоящие сетки — график по
    ///    неделям, где у отметки смысл даёт её колонка. Подпись бланка на
    ///    сорок колонок шапкой не считается.
    /// 3. **Шапки нет — повторяют ли строки одно устройство?** У записей —
    ///    да: больше половины строк начинают значения в тех же колонках, что
    ///    и самая частая. Тогда таблица, иначе — форма.
    ///
    /// Считается по якорям: копии объединений и пустые клетки в счёт не
    /// идут. Узкая таблица в две колонки — всегда таблица.
    ///
    /// Ошибка в обе стороны данных не теряет: таблица, принятая за форму,
    /// остаётся теми же значениями в том же порядке, только без сетки;
    /// форма, принятая за таблицу, — та же сетка, что и раньше.
    public enum Layout: Sendable, Equatable, Hashable {
        case table
        case form
        /// Форма с таблицей внутри: строки над шапкой и после записей —
        /// формой, шапка с записями — таблицей.
        case mixed
    }

    /// Полоса таблицы — подряд идущие строки одного вида.
    public struct Segment: Sendable, Equatable {
        public var layout: Layout
        public var table: SpannedTable
    }

    /// Вид таблицы — так, как она будет записана: без названия над ней,
    /// которое `rendered()` выносит строкой.
    public var layout: Layout { Self.summary(of: separatingCaption().table.segments()) }

    private static func summary(of parts: [Segment]) -> Layout {
        let kinds = Set(parts.map(\.layout))
        if kinds.isEmpty || kinds == [.table] { return .table }
        return kinds == [.form] ? .form : .mixed
    }

    /// Полосы таблицы.
    ///
    /// Бланк бывает с настоящей таблицей внутри: счёт-фактура — реквизиты
    /// строками, а под ними таблица товаров со своей шапкой. Целиком сеткой
    /// он раздувался вдесятеро, целиком строками — терял колонки у товаров.
    /// Поэтому расточительная сетка делится по строкам: шапка из узких
    /// подписей и записи под ней, начинающиеся в её колонках, — таблица;
    /// всё вокруг — форма. Так же Unstructured отделяет строки из одной
    /// ячейки над таблицей и под ней, а SpreadsheetLLM ищет границы таблиц
    /// по смене строения строк.
    public func segments() -> [Segment] { segmentation().parts }

    /// Полосы и Markdown всей таблицы, если она осталась одной таблицей, —
    /// тот, что построила проверка на расточительность.
    private func segmentation() -> (parts: [Segment], grid: String?) {
        let filled = cells.filter { !Self.clean($0.text).isEmpty }
        let width = cells.map { $0.column + $0.columnSpan }.max() ?? 0
        let whole = [Segment(layout: .table, table: self)]
        guard width >= 3, filled.count >= 2 else { return (whole, nil) }
        // Расточительность — по сетке, где и ячейка во всю ширину повторена в
        // каждой колонке. Её запись один раз — решение о выводе, а не
        // об устройстве таблицы: подпись во всю ширину — такой же признак
        // вёрстки, как любое объединение вбок. Мерь мы по сетке с одной
        // подписью — счёт-фактура, узнанный бланком, стал бы сеткой с
        // «ПАО ТЕЛЕКОМ-ПРИМЕР» девять раз подряд. Без таких ячеек сетки одинаковы,
        // и готовая идёт в вывод.
        let anchored = contentColumns
        let spansWholeWidth = cells.contains { spansAllContent($0, anchored: anchored) && !Self.clean($0.text).isEmpty }
        let measured = TableText.render(rows(mergingRecords: true, fullWidthOnce: false))
        let grid = spansWholeWidth ? nil : measured
        guard isWasteful(measured, filled) else { return (whole, grid) }
        let byRow = Dictionary(grouping: filled, by: \.row)
        let ordered = byRow.keys.sorted()
        // Сколько значений у каждой строки — своих и объединённых вниз сверху.
        // Считается один раз: поиск таблиц спрашивает это о каждой строке
        // каждой кандидатки, и перебор всех ячеек на каждый вопрос делал
        // большой лист квадратичным.
        let height = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        var delta = Array(repeating: 0, count: height + 1)
        for cell in filled {
            delta[cell.row] += 1
            delta[min(height, cell.row + cell.rowSpan)] -= 1
        }
        var coverage = Array(repeating: 0, count: height)
        var running = 0
        for row in 0..<height {
            running += delta[row]
            coverage[row] = running
        }
        let scan = BandScan(byRow: byRow, ordered: ordered, coverage: coverage, narrow: max(Self.headerLabelSpan, width / 4))

        var bands: [(rows: ClosedRange<Int>, headerRows: Int)] = []
        var index = 0
        while index < ordered.count {
            if let band = tableBand(at: index, below: bands.last?.rows.upperBound ?? -1, scan: scan) {
                bands.append(band)
                index = ordered[index...].firstIndex { $0 > band.rows.upperBound } ?? ordered.count
            } else {
                index += 1
            }
        }
        guard !bands.isEmpty else {
            return Self.rowsAreRecords(byRow, ordered) ? (whole, grid) : ([Segment(layout: .form, table: self)], nil)
        }
        var result: [Segment] = []
        var cursor = 0
        for band in bands {
            if cursor < band.rows.lowerBound {
                result.append(Segment(layout: .form, table: slice(cursor...(band.rows.lowerBound - 1), headerRows: nil)))
            }
            result.append(Segment(layout: .table, table: slice(band.rows, headerRows: band.headerRows)))
            cursor = band.rows.upperBound + 1
        }
        if cursor < height {
            result.append(Segment(layout: .form, table: slice(cursor...(height - 1), headerRows: nil)))
        }
        return (result.filter { segment in segment.table.cells.contains { !Self.clean($0.text).isEmpty } }, nil)
    }

    /// Markdown длиннее текста ячеек больше чем втрое: его заняли пустые
    /// клетки и копии объединений вбок. Повтор **вниз** — не лишнее, а
    /// содержание: строка несёт то, к чему относится, — и в счёт
    /// текста он идёт столько раз, сколько строк накрывает.
    private func isWasteful(_ grid: String, _ filled: [Cell]) -> Bool {
        let content = filled.reduce(0) { $0 + Self.clean($1.text).count * $1.rowSpan }
        return grid.count > content * Self.wastefulGridRatio + Self.wastefulGridSlack
    }

    /// То, что поиск таблиц спрашивает о сетке, — посчитанное один раз.
    private struct BandScan {
        let byRow: [Int: [Cell]]
        let ordered: [Int]
        /// Значений в строке — своих и объединённых вниз сверху.
        let coverage: [Int]
        /// Узкая подпись — по меркам этой сетки: на бланке в 144 колонки
        /// графа занимает пятнадцать, а название бланка — сорок.
        let narrow: Int
    }

    /// Таблица, начатая шапкой в строке `position`: узкие подписи (не шире
    /// трёх колонок или четверти таблицы, год — тоже подпись) и подряд
    /// идущие строки, у которых хотя бы половина значений начинается под
    /// ними. Ярусы шапки над ней — строки из одних подписей, растянутых над
    /// её колонками, — входят туда же.
    ///
    /// - Parameters:
    ///   - position: строка-кандидат в шапку — её место в `scan.ordered`.
    ///   - floor: последняя строка предыдущей полосы: ярусы шапки над
    ///     кандидатом ищутся только ниже неё, и полосы не перекрываются.
    private func tableBand(at position: Int, below floor: Int, scan: BandScan) -> (rows: ClosedRange<Int>, headerRows: Int)? {
        let byRow = scan.byRow, ordered = scan.ordered, narrow = scan.narrow
        let row = ordered[position]
        let labels = (byRow[row] ?? []).filter { $0.columnSpan <= narrow && Self.isLabel(Self.clean($0.text)) }
        // Три ячейки и меньше — «подпись | значение | код» бланка, а не
        // шапка: так же решает RAGFlow (строка в три ячейки — форма).
        guard labels.count > Self.formCellsPerRow else { return nil }
        // Колонки шапки — по подписям всех её ярусов: «№» и «Определение»
        // стоят в нижнем, а годы и команды — над ними.
        var columnLabels = labels
        func underLabels(_ column: Int) -> Bool {
            columnLabels.contains { $0.column <= column && column < $0.column + $0.columnSpan }
        }
        let isLabelRow: (Int) -> Bool = { row in
            (byRow[row] ?? []).allSatisfy { Self.isLabel(Self.clean($0.text)) }
        }
        // Ярусы шапки снизу: строки из одних подписей сразу под ней
        // («№ | Определение трудозатрат | …» под строкой команд). Глубина
        // шапки — в строках сетки, считая и пустые между ярусами: шапку
        // глубже трёх строк нормализация обрезает снизу, и нижняя строка
        // подписей ушла бы в данные.
        var headerEnd = row
        var cursor = position + 1
        while cursor < ordered.count, ordered[cursor] - row < Self.maximumHeaderRows, isLabelRow(ordered[cursor]) {
            headerEnd = ordered[cursor]
            columnLabels += (byRow[headerEnd] ?? []).filter { $0.columnSpan <= narrow }
            cursor += 1
        }
        // Записи — строки, начинающие значения под подписями шапки. Строка
        // в три ячейки и меньше (раздел, «Итого», подпись под таблицей)
        // остаётся в таблице, только если за ней снова идут записи: в конце
        // таблицы она — уже строка бланка.
        var lastFull = headerEnd, lastAny = headerEnd
        var full = 0, sparse = 0
        var fullColumns: Set<Int> = [], anyColumns: Set<Int> = []
        for next in ordered[cursor...] {
            let anchors = byRow[next] ?? []
            let aligned = anchors.filter { underLabels($0.column) }.count
            guard Double(aligned) >= Double(anchors.count) * 0.5 else { break }
            anyColumns.formUnion(anchors.map(\.column))
            lastAny = next
            // Значения строки — и свои, и объединённые вниз сверху: строка
            // «3 | 3,5» под «АСУБД Тип 2 | 24 | 192 | 3300» — полная запись.
            if scan.coverage[next] > Self.formCellsPerRow {
                fullColumns.formUnion(anchors.map(\.column))
                lastFull = next
                full += 1
            } else {
                sparse += 1
            }
        }
        // Одна запись под шапкой — ещё не таблица: так выглядит и строка
        // номеров граф под обрывком шапки бланка. Без полных записей таблица
        // всё же бывает — график по неделям, где в строке задача и одна
        // отметка, — но тогда у шапки много граф, а строк под ней несколько.
        let last: Int
        let recordColumns: Set<Int>
        if full >= 2 {
            (last, recordColumns) = (lastFull, fullColumns)
        } else if sparse >= Self.minimumSparseRecords, labels.count >= Self.minimumScheduleLabels {
            (last, recordColumns) = (lastAny, anyColumns)
        } else {
            return nil
        }
        guard !recordColumns.isEmpty,
              Double(recordColumns.filter(underLabels).count) >= Double(recordColumns.count) * 0.5 else { return nil }
        // Ярусы шапки сверху: подписи групп над её графами. Подпись группы
        // начинается и кончается на границах граф («Трудозатраты на 2026»
        // ровно над своими командами); реквизит бланка над таблицей так не
        // ложится — значение у него начинается посреди графы. Название
        // бланка во всю ширину шапки — не ярус: над всеми графами разом оно
        // ничего не группирует, а в шапке встало бы в имя каждой колонки.
        let starts = Set(columnLabels.map(\.column))
        let ends = Set(columnLabels.map { $0.column + $0.columnSpan })
        let left = starts.min() ?? 0, right = ends.max() ?? 0
        var top = row
        for above in ordered[..<position].reversed() {
            let anchors = byRow[above] ?? []
            guard above > floor, headerEnd - above < Self.maximumHeaderRows, isLabelRow(above),
                  anchors.allSatisfy({ starts.contains($0.column) && ends.contains($0.column + $0.columnSpan) }),
                  anchors.contains(where: { $0.columnSpan > 1 }),
                  !anchors.contains(where: { $0.column <= left && $0.column + $0.columnSpan >= right }) else { break }
            top = above
        }
        return (top...last, headerEnd - top + 1)
    }

    /// Строки повторяют одно устройство: больше половины строк начинают
    /// значения в тех же колонках, что и самая частая.
    ///
    /// Образцом пробуются самые частые устройства, а не все: на большом
    /// листе без шапки, где почти каждая строка устроена по-своему, сравнение
    /// каждого устройства с каждой строкой квадратично — шесть тысяч строк
    /// считались восемь секунд.
    private static func rowsAreRecords(_ byRow: [Int: [Cell]], _ ordered: [Int]) -> Bool {
        let patterns = ordered.compactMap { row -> Set<Int>? in
            let columns = Set((byRow[row] ?? []).map(\.column))
            return columns.count >= 2 ? columns : nil
        }
        guard patterns.count >= 2 else { return false }
        func similar(_ left: Set<Int>, _ right: Set<Int>) -> Bool {
            let common = left.intersection(right).count
            return Double(common) > Double(left.count + right.count - common) * 0.5
        }
        // Частые — по числу строк, равные — по первому появлению: выбор не
        // зависит от порядка словаря, который меняется от запуска к запуску.
        var counts: [Set<Int>: Int] = [:]
        var order: [Set<Int>] = []
        for pattern in patterns {
            if counts[pattern] == nil { order.append(pattern) }
            counts[pattern, default: 0] += 1
        }
        let candidates = order.enumerated()
            .sorted { (counts[$0.element] ?? 0, $1.offset) > (counts[$1.element] ?? 0, $0.offset) }
            .prefix(Self.recordPatternCandidates)
            .map(\.element)
        let commonest = candidates.map { candidate in patterns.filter { similar($0, candidate) }.count }.max() ?? 0
        return Double(commonest) > Double(patterns.count) * 0.5
    }

    /// Сколько самых частых устройств строк пробуется образцом.
    static let recordPatternCandidates = 32

    /// Строки `rows` отдельной таблицей. Ячейка, объединённая вниз через
    /// край полосы, входит в неё своей частью: категория слева, начатая
    /// строкой выше шапки, относится и к записям под шапкой — повтор вниз
    /// содержание, а не лишнее.
    private func slice(_ rows: ClosedRange<Int>, headerRows: Int?) -> SpannedTable {
        SpannedTable(
            cells: cells.filter { $0.row <= rows.upperBound && $0.row + $0.rowSpan > rows.lowerBound }.map { cell in
                var cell = cell
                let start = max(cell.row, rows.lowerBound)
                let end = min(cell.row + cell.rowSpan - 1, rows.upperBound)
                cell.row = start - rows.lowerBound
                cell.rowSpan = end - start + 1
                return cell
            },
            headerRows: headerRows
        )
    }

    /// Во сколько раз Markdown может быть длиннее текста ячеек, прежде чем
    /// сетка считается расточительной, — и запас на маленькие таблицы, где
    /// черты и разделитель шапки весят больше самих значений.
    static let wastefulGridRatio = 3
    static let wastefulGridSlack = 200
    /// Строка в столько ячеек и меньше — строка бланка, а не шапка
    /// таблицы (RAGFlow).
    static let formCellsPerRow = 3
    /// Таблица без полных записей — график, где в строке задача и отметка:
    /// граф в шапке не меньше стольких, строк под ней — не меньше стольких.
    static let minimumScheduleLabels = 8
    static let minimumSparseRecords = 3
    /// Подпись колонки шире этого и шире четверти таблицы — название
    /// бланка, а не графа.
    static let headerLabelSpan = 3

    /// Подпись колонки: не число и не сумма — кроме года: «2026» над
    /// колонкой подписью остаётся, а «2026 | 2027 | 2028» под
    /// «Наименование показателя» — обычная шапка расчёта.
    static func isLabel(_ text: String) -> Bool {
        guard isAmount(text) else { return true }
        let digits = text.filter(\.isNumber)
        guard digits.count == 4, digits == text.trimmingCharacters(in: .whitespaces), let year = Int(digits) else { return false }
        return (1900...2100).contains(year)
    }

    /// Подпись, растянутая вниз, повторяется в строках формы, только если
    /// она короткая: подпись даёт строке смысл («Продавец | ИНН | 7707…»),
    /// а длинный текст, растянутый на десять строк, — это содержание, и его
    /// повтор — тот же раздув, от которого форма и уходит.
    static let formCarriedLabelLength = 80

    /// Строки формы: значения слева направо, каждое объединение — один раз.
    ///
    /// **Вбок не повторяется** (исключение): в форме объединение
    /// вбок — ширина поля на бланке, а не значение нескольких граф; граф
    /// в форме нет, и повтор только множит текст. **Вниз — повторяется**,
    /// если подпись короткая и в строке есть что-то своё: так у каждой
    /// строки остаётся то, к чему она относится, — ради этого и
    /// писался. Ячейка бланка на всю высоту не в первой колонке — адресат
    /// письма справа от реквизитов — не повторяется, как и в таблице.
    /// Пустые клетки не пишутся вовсе; одинаковые значения разных ячеек
    /// остаются оба: «100 | 100» — это два значения, а не повтор.
    public func formLines() -> [String] {
        let height = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        var lines: [String] = []
        for row in 0..<height {
            let own = cells.filter { $0.row == row && !Self.clean($0.text).isEmpty }
            guard !own.isEmpty else { continue }
            let carried = cells.filter { cell in
                cell.row < row && row < cell.row + cell.rowSpan
                    && !(cell.rowSpan == height && cell.column > 0)
                    && !Self.clean(cell.text).isEmpty
                    && Self.clean(cell.text).count <= Self.formCarriedLabelLength
            }
            let line = (own + carried)
                .sorted { ($0.column, $0.row) < ($1.column, $1.row) }
                .map { TableText.escape(Self.clean($0.text)) }
                .joined(separator: " | ")
            if lines.last != line { lines.append(line) }
        }
        return lines
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Название таблицы, стоящее первой её строкой, — отдельно.
    ///
    /// «Спецификация (опись) оборудования…» одной ячейкой на всю ширину,
    /// а под ней — «№ | Наименование | Характеристика…». Шапкой Markdown
    /// становилась первая строка, то есть название, и во всех кусках
    /// таблицы вместо подписей колонок повторялось оно, а настоящая шапка
    /// уходила в данные. Название — строка из одной ячейки на всю ширину,
    /// под которой хотя бы две подписи; таких строк сверху бывает и две
    /// (название и подзаголовок). Подпись — не число и не сумма: на
    /// странице-продолжении первой строкой бывает хвост раздела во всю
    /// ширину, а под ним строка данных «#13 | 1 | 12 345 678,00», и шапкой
    /// она стать не должна. Год в шапке («2026») подписью остаётся, но
    /// и не считается: подписей-слов нужно хотя бы две.
    public func separatingCaption() -> (caption: String?, table: SpannedTable) {
        var table = self
        var captions: [String] = []
        while captions.count < 2 {
            let width = table.cells.map { $0.column + $0.columnSpan }.max() ?? 0
            let height = table.cells.map { $0.row + $0.rowSpan }.max() ?? 0
            let first = table.cells.filter { $0.row == 0 }
            let second = table.cells.filter { $0.row == 1 && !$0.text.isEmpty }
            guard width >= 2, height >= 3, first.count == 1, let title = first.first,
                  !title.text.isEmpty, title.columnSpan == width, title.rowSpan == 1,
                  Set(second.filter { !Self.isAmount($0.text) }.map(\.text)).count >= 2,
                  !second.contains(where: { Self.isMoney($0.text) }) else { break }
            captions.append(title.text)
            table.cells = table.cells.filter { $0.row > 0 }.map { cell in
                var cell = cell
                cell.row -= 1
                return cell
            }
            table.headerRows = table.headerRows.flatMap { $0 > 1 ? $0 - 1 : nil }
        }
        return (captions.isEmpty ? nil : captions.joined(separator: "\n"), table)
    }

    /// Число или сумма: «1», «2026», «12 345 678,00», «0 %».
    static func isAmount(_ text: String) -> Bool {
        let core = text.filter { !$0.isWhitespace && !"%.,-–₽$€".contains($0) }
        return !core.isEmpty && core.allSatisfy(\.isNumber)
    }

    /// Сумма с дробной частью или разрядами: «12 345 678,00», «1 234 567».
    /// Так подписи колонок не пишут, а данные — пишут.
    static func isMoney(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return isAmount(trimmed) && trimmed.contains { $0 == "," || $0 == "." || $0.isWhitespace }
    }

    /// Строки после нормализации; первая — шапка. Колонка, пустая во всей
    /// таблице, уходит: это след лишней линии сетки, а не данные. Записи
    /// нумерованной таблицы сливаются в строки — кроме таблиц PDF:
    /// там сведение ждёт, пока продолжению на следующей странице передадут
    /// шапку, иначе подписи взялись бы из первой строки данных.
    public func rows(mergingRecords: Bool = true) -> [[String]] {
        rows(mergingRecords: mergingRecords, fullWidthOnce: true)
    }

    /// - Parameter fullWidthOnce: писать ли ячейку во всю ширину один раз
    ///. `false` — прежний повтор во всех колонках: по такой сетке
    ///   меряется расточительность (`segmentation`).
    func rows(mergingRecords: Bool, fullWidthOnce: Bool) -> [[String]] {
        var rows = normalized(fullWidthOnce: fullWidthOnce)
        if let width = rows.map(\.count).max(), width > 1 {
            let kept = (0..<width).filter { column in
                rows.contains { column < $0.count && !$0[column].isEmpty }
            }
            if kept.count < width, !kept.isEmpty {
                rows = rows.map { row in kept.map { $0 < row.count ? row[$0] : "" } }
            }
        }
        return mergingRecords ? TableRecords.merged(rows) : rows
    }

    /// Колонки, где стоит хоть одна непустая ячейка, — своя, а не
    /// доставшаяся от объединения слева.
    private var contentColumns: Set<Int> {
        Set(cells.filter { !Self.clean($0.text).isEmpty }.map(\.column))
    }

    /// Ячейка во всю ширину таблицы: накрывает каждую колонку с
    /// содержимым.
    ///
    /// Не «во всю ширину сетки»: лишнюю ширину сетке даёт
    /// объединение над таблицей — «Приложение 1» в книге ФЭО на десять
    /// колонок, — а колонки за таблицей пусты и при выводе уходят. Название
    /// «Расчет стоимости человеко-месяца» на восемь колонок из восьми
    /// непустых тогда не считалось строкой во всю ширину и повторялось
    /// восемь раз подряд.
    ///
    /// - Parameter anchored: `contentColumns`, посчитанные один раз на
    ///   таблицу: спрашивают о каждой объединённой ячейке.
    private func spansAllContent(_ cell: Cell, anchored: Set<Int>) -> Bool {
        guard cell.columnSpan > 1 else { return false }
        return !anchored.isEmpty && anchored.allSatisfy { $0 >= cell.column && $0 < cell.column + cell.columnSpan }
    }

    private func normalized(fullWidthOnce: Bool) -> [[String]] {
        let width = cells.map { $0.column + $0.columnSpan }.max() ?? 0
        let height = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        guard width > 0, height > 0 else { return [] }
        let anchored = contentColumns

        // Чья клетка: номер якоря. Наложившиеся объединения (битый файл)
        // не перетирают уже занятую клетку — первый якорь главнее.
        var owner = Array(repeating: Array(repeating: Int?.none, count: width), count: height)
        for (index, cell) in cells.enumerated() {
            for row in cell.row..<(cell.row + cell.rowSpan) {
                for column in cell.column..<(cell.column + cell.columnSpan) where owner[row][column] == nil {
                    owner[row][column] = index
                }
            }
        }

        let labelRows = min(height, headerCount(owner: owner, width: width, height: height))
        let header = continuedHeader(labelRows, owner: owner, width: width, height: height)

        // 3. Шапка — одной строкой.
        var headerRow: [String] = []
        for column in 0..<width {
            var seen: [Int] = []
            for row in 0..<labelRows {
                guard let index = owner[row][column], !seen.contains(index) else { continue }
                seen.append(index)
            }
            // Подпись, растянутая вбок, повторяется над колонкой, только если
            // под ней у колонки есть своя подпись: «Единица измерения / код».
            // Без подписи снизу повтор ничего не уточняет — «Цена | Цена»,
            // а у бланка письма название ведомства вставало в шесть колонок.
            var labels: [String] = []
            for (position, index) in seen.enumerated() {
                let cell = cells[index]
                let refined = seen[(position + 1)...].contains { !cells[$0].text.isEmpty }
                guard column == cell.column || refined else { continue }
                if !cell.text.isEmpty, labels.last != cell.text { labels.append(cell.text) }
            }
            headerRow.append(labels.joined(separator: " / "))
        }

        // 1–2. Тело.
        var body: [[String]] = []
        /// Чья ячейка стоит в клетке тела — чтобы при сборке колонок по шапке
        /// одна и та же ячейка, накрывшая две клетки группы, не удвоилась.
        var bodyOwners: [[Int?]] = []
        var sections: [String?] = []
        for row in header..<height {
            var line = Array(repeating: "", count: width)
            var owners = Array(repeating: Int?.none, count: width)
            for column in 0..<width {
                guard let index = owner[row][column] else { continue }
                let cell = cells[index]
                // Вниз — в каждой строке, вбок — в каждой колонке.
                // В том числе из первой строки: у таблицы без шапки она —
                // данные, и «Крепёж» на две строки относится к обеим.
                // Настоящая многоуровневая шапка кончается вместе со своими
                // объединениями и сюда не попадает.
                //
                // Ячейка на всю высоту таблицы не в первой колонке — вёрстка
                // бланка: адресат письма справа от строк реквизитов. Его
                // повтор — шум, а не связь: он остаётся в своей клетке.
                // Колонка, которая группирует строки (раздел, категория),
                // стоит слева, и её это не касается.
                if cell.rowSpan == height, cell.column > 0,
                   row > cell.row || column > cell.column { continue }
                // Ячейка во всю ширину таблицы — подпись группы строк
                // («Процессор», «ОЗУ» в таблице «Параметр | Тип 6»), а не
                // значение колонок: своей колонки у неё нет, и повтор в
                // каждой давал «| Процессор | Процессор |». Пишется
                // один раз, в первой. В таблице от трёх колонок такая строка
                // обычно раздел и уходит в колонку «Раздел»; правило — для
                // узких таблиц и для таких ячеек, объединённых ещё и вниз.
                if fullWidthOnce, column > cell.column, spansAllContent(cell, anchored: anchored) { continue }
                line[column] = cell.text
                owners[column] = index
            }
            body.append(line)
            bodyOwners.append(owners)
            sections.append(sectionText(row: row, owner: owner, width: width))
        }

        // Колонки — по шапке, если она настоящая.
        if let groups = headerGroups(owner: owner, header: labelRows, width: width,
                                     labels: headerRow, bodyOwners: bodyOwners) {
            headerRow = groups.map { headerRow[$0.lowerBound] }
            // В колонку вывода ячейка попадает, если начинается под её
            // подписью или накрывает её целиком. Частичное перекрытие —
            // это неровная сетка Word, а не объединение: «узел», растянутый
            // мышью на клетку соседней колонки, к «Ед. измерения» не относится.
            body = zip(body, bodyOwners).map { line, owners in
                groups.map { group in
                    var seen: Set<Int> = []
                    return group.compactMap { column -> String? in
                        guard !line[column].isEmpty else { return nil }
                        guard let index = owners[column] else { return line[column] }
                        let cell = cells[index]
                        let starts = group.contains(cell.column)
                        let covers = cell.column <= group.lowerBound
                            && cell.column + cell.columnSpan >= group.upperBound
                        guard starts || covers, seen.insert(index).inserted else { return nil }
                        return line[column]
                    }.joined(separator: " ")
                }
            }
        }
        let columns = headerRow.count

        // 4. Разделы — колонкой.
        let hasData = sections.indices.contains { index in
            sections[index] == nil && sections[..<index].contains { $0 != nil }
        }
        guard hasData else {
            return header > 0 ? [headerRow] + body : body
        }
        var result: [[String]] = [[String(localized: "Раздел")] + headerRow]
        var current = ""
        /// Раздел верхнего уровня: за ним сразу идёт другой раздел, а не
        /// строки. «Услуги по модели облака» над «1. Вычислительные
        /// ресурсы» — и строке нужны оба, иначе верхний уровень оставался
        /// одинокой строкой посреди таблицы и до позиций не доходил.
        var parent: String?
        /// Нумерованы ли разделы под верхним уровнем — по первому из них.
        /// Раздел другого вида — уже не его: «Прочие работы» после
        /// «1. …», «2. …» — свой верхний уровень, а не третий подраздел.
        var childrenNumbered: Bool?
        for (index, line) in body.enumerated() {
            guard let section = sections[index] else {
                result.append([current] + line)
                continue
            }
            let nextIsSection = index + 1 < sections.count && sections[index + 1] != nil
            let hasRowsBelow = sections[(index + 1)...].contains { $0 == nil }
            if nextIsSection, hasRowsBelow {
                parent = section
                childrenNumbered = nil
                continue
            }
            if parent != nil {
                let numbered = section.first?.isNumber == true
                if let style = childrenNumbered, style != numbered {
                    parent = nil
                } else {
                    childrenNumbered = numbered
                }
            }
            current = parent.map { "\($0) / \(section)" } ?? section
            // Раздел, за которым нет ни одной строки данных, — не раздел,
            // а подпись под таблицей. Терять её нельзя.
            if !hasRowsBelow || nextIsSection {
                result.append([section] + Array(repeating: "", count: columns))
            }
        }
        return result
    }

    /// Колонки вывода — по шапке.
    ///
    /// Сетка Word неровная: человек тянет границу ячейки мышью, и в одних
    /// строках «Ед. измерения» занимает колонки 3–4, а в других «Состав
    /// услуги» растянут на 2–3, и «шт.» встаёт в четвёртую — под пустую
    /// подпись. Читает такую таблицу человек по шапке: значение относится
    /// к той подписи, под которой начинается. Так и раскладывается: колонка
    /// вывода — нижняя подпись шапки со всеми клетками сетки под ней,
    /// значения из них склеиваются («12» и «руб.» под «Цена» — «12 руб.»).
    ///
    /// Только у настоящей шапки: каждая подпись непуста, колонок хотя бы
    /// две и не меньше, чем значений в обычной строке. Заголовок таблицы
    /// на всю ширину или бланк письма шапкой не считаются, и тогда сетка
    /// остаётся как есть.
    private func headerGroups(
        owner: [[Int?]], header: Int, width: Int, labels: [String], bodyOwners: [[Int?]]
    ) -> [Range<Int>]? {
        guard header > 0 else { return nil }
        var groups: [Range<Int>] = []
        var start = 0
        for column in 1...width {
            if column == width || owner[header - 1][column] != owner[header - 1][start] {
                groups.append(start..<column)
                start = column
            }
        }
        guard groups.count >= 2, groups.count < width,
              groups.allSatisfy({ !labels[$0.lowerBound].isEmpty }) else { return nil }
        // Значения строки — ячейки, а не клетки: ячейка, растянутая вбок на
        // три клетки, — одно значение, и её копии не делают строку
        // шире шапки.
        let filled = bodyOwners.map { owners in
            Set(owners.compactMap { $0 }.filter { !Self.clean(cells[$0].text).isEmpty }).count
        }.filter { $0 > 0 }.sorted()
        guard !filled.isEmpty else { return nil }
        let typical = filled[filled.count / 2]
        return Double(groups.count) >= Double(typical) * 0.6 ? groups : nil
    }

    /// Строк шапки.
    ///
    /// Известное формату — главнее, если похоже на шапку. Word позволяет
    /// пометить «повторять как заголовок» хоть все строки таблицы, и девять
    /// таких строк над шестью позициями (таблица услуг в большом ТЗ) — флажок на всю
    /// таблицу, а не шапка. Обрезка до трёх строк уводила в шапку первую
    /// запись: «Тип услуги / Базовая Тип 1». Пометка глубже
    /// `maximumHeaderRows` в счёт не идёт, и шапка угадывается по форме.
    ///
    /// Догадка: шапка многоуровневая только у классической формы — в первой
    /// строке есть ячейка, растянутая **вниз** («№ п/п» на две строки), и
    /// ячейка, растянутая **вбок**, под которой во второй строке стоят свои
    /// подписи («Единица измерения» над «код» и «обозначение»). Одно лишь
    /// объединение вниз в первой строке шапкой не делает: так бывает и у
    /// таблиц без шапки — категория слева на три строки, — и склеить их
    /// значило бы съесть данные.
    private func headerCount(owner: [[Int?]], width: Int, height: Int) -> Int {
        if let headerRows, headerRows <= Self.maximumHeaderRows { return max(0, min(headerRows, height)) }
        guard height > 1 else { return 1 }
        let first = Set(owner[0].compactMap { $0 })
        let down = first.map { cells[$0].rowSpan }.max() ?? 1
        guard down > 1 else { return 1 }
        let depth = min(down, Self.maximumHeaderRows, height - 1)
        let hasSubheadings = first.contains { index in
            let cell = cells[index]
            guard cell.columnSpan > 1, cell.rowSpan < depth else { return false }
            let below = cell.row + cell.rowSpan
            return (cell.column..<(cell.column + cell.columnSpan)).contains { column in
                guard let other = owner[below][column], other != index else { return false }
                return !cells[other].text.isEmpty
            }
        }
        return hasSubheadings ? depth : 1
    }

    /// Шапка вместе со строками, которые её продолжают: своего текста в них
    /// нет, а клетки накрыты ячейками шапки, объединёнными вниз.
    ///
    /// «№ | Наименование | Цена», каждая объединена вниз на две строки, —
    /// шапка в одну строку подписей, но во две строки сетки. Вторая строка,
    /// оставшись в теле, выходила копией шапки — первой «записью» таблицы.
    /// Данных в такой строке нет по построению: только те же подписи.
    private func continuedHeader(_ labelRows: Int, owner: [[Int?]], width: Int, height: Int) -> Int {
        guard labelRows > 0 else { return 0 }
        var header = labelRows
        while header < height {
            var continuesHeader = false
            for column in 0..<width {
                guard let index = owner[header][column] else { continue }
                if cells[index].row < labelRows {
                    continuesHeader = true
                } else if !Self.clean(cells[index].text).isEmpty {
                    return header
                }
            }
            guard continuesHeader else { return header }
            header += 1
        }
        return header
    }

    /// Текст строки-раздела или `nil`, если строка — обычная.
    ///
    /// Раздел — одна ячейка, начатая в этой строке и занимающая всю ширину
    /// или всю, кроме номера. У узкой таблицы разделов не бывает: в две
    /// колонки «всю ширину» займёт любое примечание.
    private func sectionText(row: Int, owner: [[Int?]], width: Int) -> String? {
        guard width >= 3 else { return nil }
        var anchors: [Int] = []
        for column in 0..<width {
            if let index = owner[row][column], !anchors.contains(index) { anchors.append(index) }
        }
        guard let wide = anchors.max(by: { cells[$0].columnSpan < cells[$1].columnSpan }) else { return nil }
        let cell = cells[wide]
        guard cell.row == row, cell.rowSpan == 1, cell.columnSpan >= width - 1, !cell.text.isEmpty else {
            return nil
        }
        let others = anchors.filter { $0 != wide }
        guard others.allSatisfy({ cells[$0].text.count <= Self.sectionNumberLength && cells[$0].row == row })
        else { return nil }
        return anchors
            .sorted { cells[$0].column < cells[$1].column }
            .map { cells[$0].text }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension SpannedTable {
    /// Таблица из сетки с отметками продолжения — так её описывают Word
    /// и двоичный `.doc`: у ячейки, продолжающей объединение вниз, своего
    /// значения нет, есть только отметка.
    ///
    /// - Parameter slots: `(row, column, columnSpan, text, continuation)`;
    ///   у одной клетки может быть несколько абзацев — они склеиваются
    ///   через « / ».
    static func fromContinuations(
        _ slots: [(row: Int, column: Int, columnSpan: Int, text: String, continuation: Bool)],
        headerRows: Int? = nil
    ) -> SpannedTable {
        struct Key: Hashable { let row: Int; let column: Int }
        var order: [Key] = []
        var texts: [Key: [String]] = [:]
        var spans: [Key: Int] = [:]
        var continued: Set<Key> = []
        for slot in slots {
            let key = Key(row: slot.row, column: slot.column)
            if texts[key] == nil { order.append(key); texts[key] = [] }
            if !slot.text.isEmpty { texts[key]?.append(slot.text) }
            spans[key] = max(spans[key] ?? 1, slot.columnSpan)
            if slot.continuation { continued.insert(key) }
        }
        var cells: [Cell] = []
        for key in order where !continued.contains(key) {
            var rowSpan = 1
            while continued.contains(Key(row: key.row + rowSpan, column: key.column)) { rowSpan += 1 }
            cells.append(Cell(
                text: (texts[key] ?? []).joined(separator: " / "),
                row: key.row, column: key.column,
                rowSpan: rowSpan, columnSpan: spans[key] ?? 1
            ))
        }
        // Продолжение без начала (объединение начато в строке, которой нет,
        // или битый файл) — обычная клетка со своим текстом. Вся цепочка
        // таких продолжений, а не только верхнее: иначе второе в цепочке
        // не было ни якорем, ни клеткой, и его текст пропадал.
        func anchored(_ key: Key) -> Bool {
            var above = Key(row: key.row - 1, column: key.column)
            while texts[above] != nil {
                if !continued.contains(above) { return true }
                above = Key(row: above.row - 1, column: above.column)
            }
            return false
        }
        for key in order where continued.contains(key) {
            if !anchored(key) {
                cells.append(Cell(text: (texts[key] ?? []).joined(separator: " / "),
                                  row: key.row, column: key.column, columnSpan: spans[key] ?? 1))
            }
        }
        return SpannedTable(cells: cells, headerRows: headerRows)
    }
}
