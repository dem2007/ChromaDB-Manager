import Foundation

/// Оглавление PDF — не текст документа.
///
/// **Зачем.** В оглавлении все заголовки документа разом, и кусок с ним
/// находился по любому вопросу о любом разделе, оттесняя сам раздел. На
/// корпусе — 914 строк оглавлений в шести документах, у ТЗ на 460 страниц
/// оглавление занимает девять страниц. Заголовки же стоят и на своих местах.
///
/// **Как узнаётся.** Запись оглавления кончается отточием и номером
/// страницы («1.1 Предмет закупки ........ 18») или словами «Ошибка!
/// Закладка не определена.» — так Word печатает запись с потерянной ссылкой.
/// Убирается **блок**: от первой записи до последней, вместе со строками
/// между ними — длинная запись переносится, и её начало стоит строкой выше
/// отточия. Блок — от трёх записей, а на странице, продолжающей оглавление
/// предыдущей, — от одной: одиночное «Итого ........ 5» в бланке
/// оглавлением не считается.
enum PDFContents {
    /// Сколько строк без отточия может стоять между записями одного блока —
    /// перенос длинной записи и пустая строка между ними.
    static let maximumGap = 3
    static let minimumEntries = 3

    static func isEntry(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4, trimmed.count <= 400 else { return false }
        if trimmed.hasSuffix("Ошибка! Закладка не определена.") || trimmed.hasSuffix("Error! Bookmark not defined.") {
            return true
        }
        // Отточие с номером страницы — или отточие в конце строки: номер
        // тогда стоит строкой ниже.
        if trimmed.range(of: #"(\.{4,}|…{2,}|(\. ){4,})\s*\d{0,4}$"#, options: .regularExpression) != nil {
            return true
        }
        // Подчёркивания — только с номером страницы: строкой из
        // подчёркиваний кончаются поля бланка и реквизиты («ИНН: ______»,
        // «Директор __________»), и три таких строки подряд уходили
        // из базы «оглавлением» — вместе со вписанным в них.
        return trimmed.range(of: #"_{5,}\s*\d{1,4}$"#, options: .regularExpression) != nil
    }

    /// Хвост перенесённой записи: короткая строка, кончающаяся номером
    /// страницы («облака 53»), или сам номер. Блока не начинает, но внутри
    /// него — его часть, а не текст между записями.
    static func isEntryTail(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 100 else { return false }
        return trimmed.range(of: #"(^|\s)\d{1,4}$"#, options: .regularExpression) != nil
    }

    /// Строка, похожая на запись оглавления без отточия: начало перенесённой
    /// записи («2.1 Требования к …», «Приложение Р …») или её хвост.
    static func isEntryLike(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 200 else { return false }
        if isEntryTail(trimmed) { return true }
        if trimmed.range(of: #"^\d{1,2}(\.\d{1,3})*\.?\s+\S"#, options: .regularExpression) != nil { return true }
        return ["Приложение", "Раздел", "Глава"].contains { trimmed.hasPrefix($0) }
    }

    /// Продолжение перенесённой строки: короткая и со строчной буквы.
    static func isWrapped(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, trimmed.count <= 120 else { return false }
        return first.isLowercase
    }

    static func isTitle(_ line: String) -> Bool {
        let word = line.trimmingCharacters(in: .whitespaces).lowercased()
        return ["содержание", "оглавление", "contents", "table of contents"].contains(word)
    }

    /// Строки страницы без оглавления и число убранных строк.
    /// - Parameter continuing: предыдущая страница кончилась оглавлением.
    static func removing(_ lines: [String], continuing: Bool) -> (lines: [String], removed: Int, endsInContents: Bool) {
        let entries = lines.indices.filter { isEntry(lines[$0]) }
        guard !entries.isEmpty else { return (lines, 0, false) }

        var drop = IndexSet()
        var run: [Int] = []
        func blank(_ index: Int) -> Bool { lines[index].trimmingCharacters(in: .whitespaces).isEmpty }
        func close() {
            defer { run = [] }
            guard let first = run.first, var last = run.last else { return }
            // Страница, продолжающая оглавление, начинается его же записями:
            // начала перенесённых записей и их хвосты стоят выше первого
            // отточия.
            let isContinuation = continuing
                && lines[..<first].indices.allSatisfy { blank($0) || isEntryLike(lines[$0]) }
            guard run.count >= minimumEntries || isContinuation else { return }
            var start = isContinuation ? 0 : first
            // Начала перенесённых записей над первым отточием — тоже
            // оглавление. Только вверх: ниже оглавления текст начинается
            // заголовком «1 Общие положения», и терять его нельзя.
            while start > 0, blank(start - 1) || isEntryLike(lines[start - 1]) || isWrapped(lines[start - 1]) {
                start -= 1
            }
            while start < first, blank(start) { start += 1 }
            // Заголовок «Содержание» над первой записью.
            var probe = start - 1
            while probe >= 0, probe >= start - 2 {
                if isTitle(lines[probe]) { start = probe; break }
                if !blank(probe) { break }
                probe -= 1
            }
            // Хвост последней перенесённой записи — строкой ниже отточия.
            while last + 1 < lines.count, isEntryTail(lines[last + 1]) { last += 1 }
            drop.insert(integersIn: start...last)
        }
        for index in entries {
            if let last = run.last {
                // Переносы длинной записи и начала следующих — не текст
                // между записями, а сами записи.
                let between = lines[(last + 1)..<index].filter {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                        && !isEntryTail($0) && !isEntryLike($0) && !isWrapped($0)
                }
                if between.count > maximumGap - 1 { close() }
            }
            run.append(index)
        }
        close()
        guard let lastDropped = drop.last else { return (lines, 0, false) }
        // Оглавление идёт до конца страницы — следующая, скорее всего,
        // его продолжает. Номер страницы внизу листа продолжению не мешает.
        let tail = lines[(lastDropped + 1)...].allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || (trimmed.count <= 4 && trimmed.allSatisfy(\.isNumber))
        }
        let kept = lines.indices.filter { !drop.contains($0) }.map { lines[$0] }
        let removed = drop.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }.count
        return (kept, removed, tail)
    }
}
