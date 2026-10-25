import Foundation

/// Шапка листа в несколько строк — в названия колонок.
///
/// **Зачем.** Строка шапки — одна, её выбирает автоопределение или человек.
/// А в расчётах трудозатрат над ролями стоят ещё две: «Затраты на 2026 г»
/// на тридцать колонок и команда на пять. Записи получали названия по нижней
/// строке, повторы различались номерами — «Архитектор», «Архитектор (2)»,
/// «Архитектор (3)», — и какой из них 2027 год, из записи узнать было нельзя.
/// Так было на 36 листах из 150.
///
/// **Как.** Над строкой шапки берутся строки, где ячейки объединены вбок над
/// группой колонок, — сколько их подряд, но не больше трёх. Название колонки —
/// подписи этих строк сверху вниз и её собственная, через « / »: «Затраты
/// на 2030 г / Группа сопровождения / Инженер».
/// Опора — объединения, заданные в файле: строки без них — служебные
/// (вспомогательные формулы, повторы) или название отчёта, и шапкой не
/// считаются.
///
/// **Что не меняется.** Колонка по-прежнему называется своей подписью из
/// строки шапки: по ней сопоставляют профиль, роли и шаблон. Склеенное
/// название — только **видимое**: подпись в тексте записи и ключ
/// метаданных, и только там, где человек не задал своё.
public enum SheetHeaderLabels {
    /// Строк над шапкой — не больше стольких.
    public static let maximumParentRows = 3

    /// Названия колонок с подписями над шапкой, или `nil`, если шапка
    /// в одну строку.
    public static func labels(
        rows: [SheetRow], headerRow: Int, merges: [XLSXReader.MergedRange], width: Int
    ) -> [String]? {
        guard headerRow >= 1, width > 0,
              let header = rows.first(where: { $0.number == headerRow }) else { return nil }
        let byNumber = Dictionary(rows.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        func text(_ row: Int, _ column: Int) -> String {
            clean(byNumber[row]?.value(at: column).displayText ?? "")
        }
        let (left, right) = span(of: header, headerRow: headerRow, merges: merges, width: width)
        guard let leftmost = left, let rightmost = right else { return nil }

        let parents = parentRows(leftmost: leftmost, rightmost: rightmost, headerRow: headerRow, merges: merges)

        // Строки под шапкой, которые её продолжают: подписи, объединённые
        // вниз, накрывают и их. Своё значение у такой строки — подпись под
        // группой («2026» над «Стоимость»), а повтор объединённой сверху —
        // не подпись.
        let children = headerRow < continuationEnd(headerRow: headerRow, merges: merges)
            ? Array((headerRow + 1)...continuationEnd(headerRow: headerRow, merges: merges)) : []
        guard !parents.isEmpty || !children.isEmpty else { return nil }
        func spilled(_ row: Int, _ column: Int) -> Bool {
            merges.contains {
                $0.firstRow < row && row <= $0.lastRow && $0.firstColumn <= column && column <= $0.lastColumn
            }
        }
        // Объединение над строкой шапки, накрывающее колонку, — подпись
        // группы и в самой шапке: «2026» на четыре колонки стоит у первой.
        func group(_ row: Int, _ column: Int) -> String {
            let range = merges.first {
                $0.firstRow <= row && row <= $0.lastRow && $0.firstColumn <= column && column <= $0.lastColumn
            }
            return range.map { text($0.firstRow, $0.firstColumn) } ?? text(row, column)
        }

        // Имена колонок — те же, что у сопоставления: повторы с номерами,
        // «Архитектор (2)». Колонка, которой подписи сверху ничего не
        // добавили, остаётся при своём имени: иначе «Архитектор (2)» получал
        // видимое название «Архитектор» и снова не отличался от первого.
        let titles = TableProfileMatcher.uniqued(SheetModeDetector.headerTitles(header, width: width))
        var labels: [String] = []
        var refined = false
        for column in 0..<width {
            var parts: [String] = []
            for parent in parents {
                let label = group(parent, column)
                if !label.isEmpty, parts.last != label { parts.append(label) }
            }
            // Своя подпись колонки; буква вместо подписи (ячейка шапки пуста)
            // подписью не считается.
            let own = children.isEmpty ? clean(header.value(at: column).displayText) : group(headerRow, column)
            if !own.isEmpty, parts.last != own { parts.append(own) }
            for child in children where !spilled(child, column) {
                let label = text(child, column)
                if !label.isEmpty, parts.last != label { parts.append(label) }
            }
            if parts.count > 1 { refined = true }
            // Своя подпись пуста, а над колонкой группа — подпись группы
            // и есть её название.
            let named = parts.count > 1 || (parts.count == 1 && own.isEmpty)
            labels.append(named ? parts.joined(separator: " / ") : titles[column])
        }
        // Две колонки под одной группой с одной подписью — тоже повтор.
        return refined ? TableProfileMatcher.uniqued(labels) : nil
    }

    /// Строки над шапкой с объединениями вбок — подписи групп, сверху вниз.
    /// Строка, где одно объединение накрывает всю шапку, — название таблицы:
    /// на ней подъём кончается, и она в подписи не идёт.
    public static func parentRows(
        rows: [SheetRow], headerRow: Int, merges: [XLSXReader.MergedRange], width: Int
    ) -> [Int] {
        guard let header = rows.first(where: { $0.number == headerRow }) else { return [] }
        let (leftmost, rightmost) = span(of: header, headerRow: headerRow, merges: merges, width: width)
        guard let leftmost, let rightmost else { return [] }
        return parentRows(leftmost: leftmost, rightmost: rightmost, headerRow: headerRow, merges: merges)
    }

    /// Ширина шапки: её подписи и колонки, закрытые объединениями, которые
    /// спускаются в неё сверху («№» на две строки над пустой клеткой).
    /// Без них объединение над частью шапки казалось накрывающим всю
    /// шапку и принималось за название таблицы.
    static func span(
        of header: SheetRow, headerRow: Int, merges: [XLSXReader.MergedRange], width: Int
    ) -> (Int?, Int?) {
        var columns = Set((0..<width).filter { !header.value(at: $0).isEmpty })
        for range in merges where range.firstRow < headerRow && headerRow <= range.lastRow {
            columns.formUnion(range.firstColumn...range.lastColumn)
        }
        return (columns.min(), columns.max())
    }

    static func parentRows(
        leftmost: Int, rightmost: Int, headerRow: Int, merges: [XLSXReader.MergedRange]
    ) -> [Int] {
        let sideways = merges.filter { $0.spansColumns && $0.lastRow < headerRow }
        var parents: [Int] = []
        var row = headerRow - 1
        while row >= 1, parents.count < maximumParentRows {
            let here = sideways.filter { $0.firstRow <= row && row <= $0.lastRow }
            guard !here.isEmpty,
                  !here.contains(where: { $0.firstColumn <= leftmost && rightmost <= $0.lastColumn })
            else { break }
            parents.insert(row, at: 0)
            row -= 1
        }
        return parents
    }

    /// Последняя строка шапки: строка шапки или ниже, докуда её подписи
    /// объединены вниз. Объединение длиннее трёх строк под шапкой — уже
    /// не подпись, а колонка-раздел вдоль данных, и шапку оно не продлевает.
    public static func continuationEnd(headerRow: Int, merges: [XLSXReader.MergedRange]) -> Int {
        merges
            .filter { $0.firstRow <= headerRow && headerRow < $0.lastRow && $0.lastRow <= headerRow + maximumParentRows }
            .map(\.lastRow).max() ?? headerRow
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

extension TableMapping {
    /// Сопоставление с видимыми названиями колонок из шапки в несколько строк
    ///. Своё название человека главнее — его колонки не трогаются.
    public func labelled(by labels: [String], layout: SheetLayout) -> TableMapping {
        var mapping = self
        for column in columns where (titles[column] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            guard let index = layout.index(of: column), index < labels.count else { continue }
            let label = labels[index]
            if label != column, !label.isEmpty { mapping.titles[column] = label }
        }
        return mapping
    }

    /// То же — прямо по листу: строки, объединения и строка шапки.
    public func labelled(rows: [SheetRow], merges: [XLSXReader.MergedRange], layout: SheetLayout) -> TableMapping {
        guard !usesColumnLetters, let headerRow = layout.headerRow, headerRow > 0 else { return self }
        let width = rows.map { $0.lastColumn + 1 }.max() ?? 0
        guard let labels = SheetHeaderLabels.labels(rows: rows, headerRow: headerRow, merges: merges, width: width)
        else { return self }
        return labelled(by: labels, layout: layout)
    }
}
