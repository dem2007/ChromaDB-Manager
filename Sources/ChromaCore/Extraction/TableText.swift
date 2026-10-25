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
    ///
    /// Обратная черта удваивается, только когда её иначе прочли бы как
    /// экранирование (`cells(of:)`): перед `\`, `|` и в конце значения.
    /// Путь `C:\Users` остаётся как есть.
    public static func escape(_ value: String) -> String {
        var doubled = ""
        let characters = Array(value)
        for (index, character) in characters.enumerated() {
            doubled.append(character)
            guard character == "\\" else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if next == nil || next == "\\" || next == "|" { doubled.append("\\") }
        }
        return doubled
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// Ячейки строки `| раз | два |` — обратно в значения.
    /// Экранированная труба `\|` остаётся в значении трубой, удвоенная
    /// обратная черта `\\` — одной (`escape`).
    public static func cells(of line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("|"), body.hasSuffix("|"), body.count >= 2 else { return [body] }
        body = String(body.dropFirst().dropLast())
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                if character != "|", character != "\\" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
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

    /// Ряд нумерации колонок: «1 | 2 | 3 | …», «А | 1 | 1а | 2 | …».
    ///
    /// Его ставят под шапкой формы, чтобы ссылаться на графы («графа 5»).
    /// Данных в нём нет: в документе это лишняя строка в каждом куске таблицы,
    /// а в книге Excel — запись «Наименование: 2 / Роль: 3» со значениями
    /// 1…102. Узнаётся по виду: хотя бы три заполненные ячейки, каждая —
    /// номер графы (число до трёх цифр, с буквой или без, или одна заглавная
    /// буква), числа начинаются с единицы или двойки и растут — на единицу,
    /// изредка через одну. Повтор числа — только графа с буквой («1», «1а»):
    /// строка количеств «1 | 1 | 2 | 3» нумерацией не считается.
    public static func isColumnNumbering(_ cells: [String]) -> Bool {
        let filled = cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard filled.count >= 3 else { return false }
        var numbers: [(value: Int, lettered: Bool)] = []
        for cell in filled {
            if cell.count == 1, let letter = cell.first, letter.isUppercase, letter.isLetter { continue }
            let digits = cell.prefix { $0.isNumber }
            let rest = cell.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 3, rest.count <= 1, rest.allSatisfy(\.isLetter),
                  let number = Int(digits) else { return false }
            numbers.append((number, !rest.isEmpty))
        }
        guard numbers.count >= 3, let first = numbers.first, first.value <= 2 else { return false }
        var unit = 0
        for (left, right) in zip(numbers, numbers.dropFirst()) {
            switch right.value - left.value {
            case 1: unit += 1
            case 2: continue
            case 0 where right.lettered: continue
            default: return false
            }
        }
        // Шаг через одну — пропущенная графа, а не правило.
        return unit * 2 >= numbers.count - 1
    }

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
