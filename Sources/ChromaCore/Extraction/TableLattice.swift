import Foundation
import CoreGraphics

/// Таблица по линиям рамки — для всего, где рамку видно: векторный PDF
/// и картинка скана.
///
/// **Зачем, если есть `TableGeometry`.** Та собирает таблицу по тому, где
/// стоит текст, и упирается в то, чего по тексту не видно. Ячейка в две
/// строки выглядит как две строки таблицы. Значение, выровненное по середине
/// объединённой ячейки, стоит на высоте одной из строк, а к остальным
/// не относится ни к какой. Замер на 58 PDF корпуса: из 484 страниц с рамкой
/// таблица собиралась на 128, и на странице прайса цены уходили в конец
/// текста отдельно от позиций.
///
/// Рамка знает то, чего не знает текст: где кончается ячейка. Линия между
/// двумя клетками сетки есть — это разные ячейки; линии нет — одна,
/// объединённая. Отсюда и объединения: ячейка «Поставка оборудования…»
/// на восемь строк — это восемь клеток без линий между ними.
///
/// Координаты — как в PDF: `y` растёт вверх, строки сетки идут сверху вниз,
/// то есть по убыванию `y`. Скан переводится в те же координаты.
enum TableLattice {
    /// Отрезок рамки. У горизонтального `position` — это `y`, а `from…to` —
    /// по `x`; у вертикального наоборот.
    struct Segment: Equatable {
        var position: Double
        var from: Double
        var to: Double
    }

    struct Rulings {
        var horizontal: [Segment] = []
        var vertical: [Segment] = []
    }

    /// Ячейка сетки после объединений: место в сетке и прямоугольник.
    struct Region: Equatable {
        var row: Int
        var column: Int
        var rowSpan: Int
        var columnSpan: Int
        var rect: CGRect
    }

    struct Grid {
        /// Границы колонок слева направо.
        var xs: [Double]
        /// Границы строк сверху вниз — по убыванию `y`.
        var ys: [Double]
        var regions: [Region]
        /// Номер региона для каждой клетки `[строка][колонка]`.
        var owner: [[Int]]

        var bounds: CGRect {
            CGRect(x: xs[0], y: ys[ys.count - 1], width: xs[xs.count - 1] - xs[0], height: ys[0] - ys[ys.count - 1])
        }

        /// Регион, в который попадает точка, — по клетке сетки.
        func region(at point: CGPoint) -> Int? {
            let x = Double(point.x), y = Double(point.y)
            guard x >= xs[0], x <= xs[xs.count - 1], y <= ys[0], y >= ys[ys.count - 1] else { return nil }
            guard let column = (0..<(xs.count - 1)).first(where: { x <= xs[$0 + 1] }),
                  let row = (0..<(ys.count - 1)).first(where: { y >= ys[$0 + 1] }) else { return nil }
            return owner[row][column]
        }
    }

    // MARK: - Отрезки в сетки

    /// Сетки страницы.
    ///
    /// - Parameter tolerance: на сколько могут расходиться концы и положения
    ///   отрезков одной линии. Для PDF — пара пунктов: Word рисует рамку
    ///   ячейки отдельным прямоугольником, и у соседних ячеек линии
    ///   смещены на толщину. Для скана — больше: линия там толщиной в
    ///   несколько точек и с перекосом.
    /// - Parameter sparse: доля высоты (для границ колонок) и ширины (для
    ///   границ строк) таблицы, которую линия должна закрыть, чтобы считаться
    ///   границей. Для вектора — ноль: там линия либо нарисована, либо нет.
    ///   Для скана — заметно больше: ложная линия из склеенных штрихов букв
    ///   бывает в паре строк, настоящая граница колонки идёт почти через всю
    ///   таблицу.
    static func grids(from rulings: Rulings, tolerance: Double, sparse: (columns: Double, rows: Double) = (0, 0)) -> [Grid] {
        let horizontal = merged(rulings.horizontal, tolerance: tolerance)
        let vertical = merged(rulings.vertical, tolerance: tolerance)
        guard horizontal.count >= 2, !vertical.isEmpty else { return [] }

        // Связные группы: горизонталь и вертикаль связаны, если пересекаются
        // или касаются. Таблицы страницы — разные группы.
        let all = horizontal.count + vertical.count
        var parent = Array(0..<all)
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        for (h, line) in horizontal.enumerated() {
            for (v, column) in vertical.enumerated()
            where column.position >= line.from - tolerance && column.position <= line.to + tolerance
                && line.position >= column.from - tolerance && line.position <= column.to + tolerance {
                parent[find(h)] = find(horizontal.count + v)
            }
        }
        var groups: [Int: (h: [Segment], v: [Segment])] = [:]
        for (index, line) in horizontal.enumerated() { groups[find(index), default: ([], [])].h.append(line) }
        for (index, line) in vertical.enumerated() {
            groups[find(horizontal.count + index), default: ([], [])].v.append(line)
        }
        return groups.values
            .compactMap { grid(horizontal: $0.h, vertical: $0.v, tolerance: tolerance, sparse: sparse) }
            .sorted { $0.ys[0] > $1.ys[0] }
    }

    /// Отрезки одной линии — одним: рамка ячеек рисуется кусками.
    ///
    /// - Parameter gap: разрыв, который ещё не разрыв; по умолчанию — допуск.
    static func merged(_ segments: [Segment], tolerance: Double, gap: Double? = nil) -> [Segment] {
        let gap = gap ?? tolerance
        let sorted = segments.sorted { $0.position < $1.position }
        var lines: [[Segment]] = []
        for segment in sorted {
            if let last = lines.last?.first, segment.position - last.position <= tolerance {
                lines[lines.count - 1].append(segment)
            } else {
                lines.append([segment])
            }
        }
        var result: [Segment] = []
        for line in lines {
            let position = line.map(\.position).reduce(0, +) / Double(line.count)
            var pieces = line.sorted { $0.from < $1.from }
            var current = pieces.removeFirst()
            current.position = position
            for piece in pieces {
                if piece.from <= current.to + gap {
                    current.to = max(current.to, piece.to)
                } else {
                    result.append(current)
                    current = Segment(position: position, from: piece.from, to: piece.to)
                }
            }
            result.append(current)
        }
        return result
    }

    /// Положения линий — сгустками: две линии ближе допуска — одна.
    static func clustered(_ values: [Double], tolerance: Double) -> [Double] {
        var result: [[Double]] = []
        for value in values.sorted() {
            if let last = result.last?.last, value - last <= tolerance {
                result[result.count - 1].append(value)
            } else {
                result.append([value])
            }
        }
        return result.map { $0.reduce(0, +) / Double($0.count) }
    }

    /// Сетка одной группы отрезков, или `nil`, если это не таблица.
    static func grid(
        horizontal: [Segment], vertical: [Segment], tolerance: Double,
        sparse: (columns: Double, rows: Double) = (0, 0)
    ) -> Grid? {
        guard horizontal.count >= 2, !vertical.isEmpty else { return nil }
        var xs = clustered(vertical.map(\.position), tolerance: tolerance)
        var ys = clustered(horizontal.map(\.position), tolerance: tolerance).reversed().map { $0 }
        if sparse.columns > 0 || sparse.rows > 0, let top = ys.first, let bottom = ys.last,
           let left = xs.first, let right = xs.last {
            func length(_ lines: [Segment], at position: Double, from low: Double, to high: Double) -> Double {
                lines.filter { abs($0.position - position) <= tolerance }
                    .reduce(0) { $0 + max(0, min($1.to, high) - max($1.from, low)) }
            }
            let height = top - bottom
            let width = right - left
            if height > 0 {
                xs = xs.filter { length(vertical, at: $0, from: bottom, to: top) >= height * sparse.columns }
            }
            if width > 0 {
                ys = ys.filter { length(horizontal, at: $0, from: left, to: right) >= width * sparse.rows }
            }
            guard xs.count >= 2, ys.count >= 2 else { return nil }
        }
        // Таблица без боковых линий: края — по концам горизонталей. Без
        // этого крайние колонки, у которых нет линии снаружи, терялись бы
        // вместе с текстом.
        let left = horizontal.map(\.from).min() ?? xs[0]
        let right = horizontal.map(\.to).max() ?? xs[xs.count - 1]
        if left < xs[0] - tolerance * 2 { xs.insert(left, at: 0) }
        if right > xs[xs.count - 1] + tolerance * 2 { xs.append(right) }
        let top = vertical.map(\.to).max() ?? ys[0]
        let bottom = vertical.map(\.from).min() ?? ys[ys.count - 1]
        if top > ys[0] + tolerance * 2 { ys.insert(top, at: 0) }
        if bottom < ys[ys.count - 1] - tolerance * 2 { ys.append(bottom) }
        let rows = ys.count - 1
        let columns = xs.count - 1
        // Таблица — хотя бы две строки и две колонки. Одна клетка — рамка
        // вокруг абзаца; строка клеток или столбец — рамки блоков схемы
        // или полоса подписей, и разбирать их как таблицу незачем.
        guard rows >= 2, columns >= 2 else { return nil }

        // Линия между клетками есть, если она закрывает хотя бы четверть
        // их общей стороны. Не по одной средней точке: у линии скана бывают
        // разрывы, и разрыв ровно посередине сливал две строки цен в одну
        // «объединённую» ячейку.
        func covered(_ lines: [Segment], at position: Double, from start: Double, to end: Double) -> Bool {
            let low = min(start, end), high = max(start, end)
            var pieces = lines
                .filter { abs($0.position - position) <= tolerance && $0.to > low && $0.from < high }
                .map { (max($0.from, low), min($0.to, high)) }
                .sorted { $0.0 < $1.0 }
            guard !pieces.isEmpty else { return false }
            var total = 0.0
            var current = pieces.removeFirst()
            for piece in pieces {
                if piece.0 <= current.1 { current.1 = max(current.1, piece.1) } else {
                    total += current.1 - current.0
                    current = piece
                }
            }
            total += current.1 - current.0
            return total >= (high - low) * 0.25
        }
        func hasVertical(at x: Double, between top: Double, and bottom: Double) -> Bool {
            covered(vertical, at: x, from: bottom, to: top)
        }
        func hasHorizontal(at y: Double, between left: Double, and right: Double) -> Bool {
            covered(horizontal, at: y, from: left, to: right)
        }

        // Клетки без линии между ними — одна ячейка.
        var parent = Array(0..<(rows * columns))
        func find(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                if column + 1 < columns,
                   !hasVertical(at: xs[column + 1], between: ys[row], and: ys[row + 1]) {
                    parent[find(index)] = find(index + 1)
                }
                if row + 1 < rows,
                   !hasHorizontal(at: ys[row + 1], between: xs[column], and: xs[column + 1]) {
                    parent[find(index)] = find(index + columns)
                }
            }
        }

        var regionOf: [Int: Int] = [:]
        var regions: [Region] = []
        var owner = Array(repeating: Array(repeating: 0, count: columns), count: rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let root = find(row * columns + column)
                if let known = regionOf[root] {
                    owner[row][column] = known
                    let region = regions[known]
                    // Объединение — по охватывающему прямоугольнику: фигура
                    // «буквой Г» бывает только у битой рамки.
                    let lastRow = max(region.row + region.rowSpan - 1, row)
                    let lastColumn = max(region.column + region.columnSpan - 1, column)
                    let firstColumn = min(region.column, column)
                    regions[known].column = firstColumn
                    regions[known].rowSpan = lastRow - region.row + 1
                    regions[known].columnSpan = lastColumn - firstColumn + 1
                } else {
                    regionOf[root] = regions.count
                    owner[row][column] = regions.count
                    regions.append(Region(row: row, column: column, rowSpan: 1, columnSpan: 1, rect: .zero))
                }
            }
        }
        guard regions.count >= 2 else { return nil }
        for index in regions.indices {
            let region = regions[index]
            regions[index].rect = CGRect(
                x: xs[region.column], y: ys[region.row + region.rowSpan],
                width: xs[region.column + region.columnSpan] - xs[region.column],
                height: ys[region.row] - ys[region.row + region.rowSpan]
            )
        }
        return Grid(xs: xs, ys: ys, regions: regions, owner: owner)
    }

    // MARK: - Текст в ячейки

    /// Доля ячеек с текстом, ниже которой сетка — не таблица.
    static let minimumFilledShare = 0.3

    /// Доля ячеек сетки, где уже есть текст.
    static func filledShare(_ grid: Grid, words: [TableGeometry.Word]) -> Double {
        var filled = Set<Int>()
        for word in words {
            if let region = grid.region(at: CGPoint(x: word.box.midX, y: word.box.midY)) { filled.insert(region) }
        }
        return grid.regions.isEmpty ? 0 : Double(filled.count) / Double(grid.regions.count)
    }

    /// Таблица сетки с текстом. Возвращает и номера кусков текста, ушедших
    /// в таблицу, — остальные остаются текстом страницы.
    ///
    /// Текст ячейки — её строки через пробел: ячейка в три строки — одно
    /// значение, а не три строки таблицы. Дефис на конце строки остаётся
    /// и пробела за ним нет: «ИТ-» и «инфраструктуры» — «ИТ-инфраструктуры»,
    /// ««Пример-» и «Сервис»» — «Пример-Сервис»; убрать дефис значило бы
    /// угадывать, перенос это или часть слова.
    static func table(
        _ grid: Grid, words: [TableGeometry.Word], height: Double, separated: Bool
    ) -> (table: SpannedTable, used: Set<Int>)? {
        var byRegion: [Int: [TableGeometry.Word]] = [:]
        var used: Set<Int> = []
        for (index, word) in words.enumerated() {
            guard let region = grid.region(at: CGPoint(x: word.box.midX, y: word.box.midY)) else { continue }
            byRegion[region, default: []].append(word)
            used.insert(index)
        }
        var cells: [SpannedTable.Cell] = []
        for (index, region) in grid.regions.enumerated() {
            let mine = byRegion[index] ?? []
            var column = region.column
            var columnSpan = region.columnSpan
            // Ячейка шириной в несколько колонок, а текст весь в одной из них:
            // линию между ними не дорисовали (на скане она рвётся), и итог,
            // стоящий под «Стоимостью», уехал бы под «Цену» — в первую
            // колонку объединения. Только у скана: в векторе линия либо
            // нарисована, либо нет, и её отсутствие — настоящее объединение,
            // хоть подпись и прижата влево.
            if separated, columnSpan > 1, region.rowSpan == 1, !mine.isEmpty {
                let left = mine.map { Double($0.box.minX) }.min() ?? 0
                let right = mine.map { Double($0.box.maxX) }.max() ?? 0
                let holding = (region.column..<(region.column + region.columnSpan)).filter {
                    left >= grid.xs[$0] - 2 && right <= grid.xs[$0 + 1] + 2
                }
                if holding.count == 1 {
                    column = holding[0]
                    columnSpan = 1
                }
            }
            let lines = TableGeometry.lines(from: mine, height: height, separated: separated)
            var text = ""
            for line in lines.map(\.text) where !line.isEmpty {
                if text.isEmpty {
                    text = line
                } else if text.hasSuffix("-"), line.first?.isLetter == true {
                    text += line
                } else {
                    text += " " + line
                }
            }
            cells.append(SpannedTable.Cell(
                text: text, row: region.row, column: column,
                rowSpan: region.rowSpan, columnSpan: columnSpan
            ))
        }
        // Таблица — когда текст хотя бы в двух ячейках и хотя бы в трети
        // их. Одна заполненная клетка в рамке — рамка вокруг текста;
        // сетка, где почти всё пусто, — блоки схемы со значками.
        let filled = cells.filter { !$0.text.isEmpty }.count
        guard filled >= 2, Double(filled) >= Double(cells.count) * minimumFilledShare else { return nil }
        return (SpannedTable(cells: cells), used)
    }
}
