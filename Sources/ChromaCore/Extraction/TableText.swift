import Foundation

/// Таблица в текст — один вид на все источники.
///
/// **Зачем один вид.** До этого одна и та же таблица приходила в базу
/// по-разному в зависимости от того, в чём её сохранили: из книги Excel —
/// разметкой Markdown со строкой заголовков, из Word — ячейками через
/// табуляцию, из PDF — как придётся. Для человека это мелочь, для базы — нет:
/// чанки одного и того же прайса из двух форматов не совпадают ни текстом,
/// ни длиной, поиск по ним даёт разные результаты, а сравнить их между собой
/// нельзя.
///
/// **Почему именно Markdown.** Он остаётся таблицей и в куске: строка
/// заголовков и разделитель под ней читаются и человеком, и моделью, и — что
/// важнее всего — по разделителю **машинно опознаётся шапка**, которую нарезка
/// повторяет в каждом куске длинной таблицы. У ячеек через табуляцию
/// такого признака нет вовсе: кусок из середины таблицы — сетка значений
/// без единого названия колонки.
public enum TableText {
    /// Строка значений: `| раз | два | три |`.
    public static func row(_ values: [String]) -> String {
        "| " + values.map(escape).joined(separator: " | ") + " |"
    }

    /// Разделитель под строкой заголовков — им таблица и опознаётся.
    public static func separator(width: Int) -> String {
        "|" + String(repeating: " --- |", count: max(1, width))
    }

    /// Труба внутри ячейки закрыла бы колонку раньше времени, перевод строки —
    /// строку. И то и другое экранируется, а не выбрасывается: значение чужое.
    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// Готовая таблица: первая строка — заголовки, под ней разделитель.
    ///
    /// Первая строка считается шапкой всегда. Это не догадка, а соглашение
    /// формата: у таблицы без заголовков первая строка всё равно окажется
    /// в каждом куске, и это лучше, чем ни одной. Узкие места честнее:
    /// таблица из одной колонки таблицей не оформляется — рамка вокруг списка
    /// строк только мешает.
    public static func render(_ rows: [[String]]) -> String {
        let filled = rows.filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let width = filled.map(\.count).max(), width > 1 else {
            return filled.map { $0.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        func padded(_ values: [String]) -> [String] {
            values + Array(repeating: "", count: width - values.count)
        }
        var lines = [row(padded(filled[0])), separator(width: width)]
        for values in filled.dropFirst() { lines.append(row(padded(values))) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Узнавание

    /// Строка таблицы — по обрамляющим трубам.
    public static func isRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2
    }

    /// Разделитель под шапкой: `| --- | --- |`.
    public static func isSeparator(_ line: String) -> Bool {
        guard isRow(line) else { return false }
        let body = line.trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
        let cells = body.components(separatedBy: "|")
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
