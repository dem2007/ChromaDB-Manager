import Foundation

/// Таблица стилей двоичного `.doc` — ступень 3.
///
/// Ради двух вещей. Первая — **структура из разметки автора**: абзац,
/// набранный стилем «Заголовок 2», должен давать заголовок второго уровня,
/// а не участвовать в угадывании по кеглю. Вторая менее очевидна и не менее
/// важна: начертание и кегль в `.doc` чаще всего **не** записаны у самого
/// текста, они приходят из стиля. Без таблицы стилей документ выглядит
/// набранным одним шрифтом без единого выделения — и догадка по кеглю,
/// на которую опираются файлы без разметки, перестаёт работать вовсе.
struct DocStyleTable {
    struct Style {
        var name = ""
        /// Номер встроенного стиля: 1…9 — «Заголовок 1»…«Заголовок 9».
        var sti = 0x0FFF
        /// Уровень структуры, заданный самим стилем.
        var outline: Int?
        /// Стиль, от которого этот унаследован.
        var base: Int?
        var isBold: Bool?
        var halfPoints: Int?
    }

    var styles: [Int: Style] = [:]

    /// Свойства стиля с учётом наследования.
    ///
    /// Цепочка обрывается на десятом шаге: файл может описывать кольцо,
    /// и разбирать его до упора значит зациклиться на чужой ошибке.
    func resolved(_ istd: Int) -> Style? {
        var result = styles[istd]
        var current = result
        var steps = 0
        while let style = current, let base = style.base, base != istd, steps < 10 {
            guard let parent = styles[base] else { break }
            if result?.isBold == nil { result?.isBold = parent.isBold }
            if result?.halfPoints == nil { result?.halfPoints = parent.halfPoints }
            if result?.outline == nil { result?.outline = parent.outline }
            current = parent
            steps += 1
        }
        return result
    }

    /// Уровень заголовка, если этот стиль — заголовок.
    func headingLevel(of istd: Int) -> Int? {
        guard let style = resolved(istd) else { return nil }
        if let outline = style.outline, (0...8).contains(outline) { return outline + 1 }
        if (1...9).contains(style.sti) { return style.sti }
        return Self.headingLevel(inName: style.name)
    }

    /// Уровень по имени стиля. Имя встроенного стиля Word часто не пишет
    /// вовсе — тогда работает номер, — но у переименованных и у чужих
    /// заголовков остаётся только оно.
    static func headingLevel(inName name: String) -> Int? {
        let lowered = name.lowercased()
        for prefix in ["heading", "заголовок", "überschrift", "titre"] where lowered.hasPrefix(prefix) {
            let rest = lowered.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let level = Int(rest.prefix(1)), (1...9).contains(level) { return level }
        }
        return nil
    }
}

extension DocPartsReader {
    /// Таблица стилей из потока таблиц. Пустая — значит, разметки нет,
    /// и структуру придётся угадывать, как и раньше.
    func styleTable() -> DocStyleTable {
        var result = DocStyleTable()
        guard let location = fib.location(of: .stshf),
              location.fc >= 0, location.fc + location.lcb <= table.count
        else { return result }

        let header = Int(CFBContainerReader.u16(table, location.fc))
        guard header >= 8 else { return result }
        let count = Int(CFBContainerReader.u16(table, location.fc + 2))
        // Длина неизменной части записи объявлена в самой таблице: у разных
        // версий Word она разная, и читать по постоянному смещению нельзя.
        let baseSize = Int(CFBContainerReader.u16(table, location.fc + 4))
        guard count > 0, count < 10_000, baseSize >= 8 else { return result }

        var offset = location.fc + 2 + header
        let end = location.fc + location.lcb
        for istd in 0..<count {
            guard offset + 2 <= end else { break }
            let size = Int(CFBContainerReader.u16(table, offset))
            offset += 2
            guard size > 0 else { continue }
            guard offset + size <= end else { break }
            if size >= baseSize + 2 {
                let record = table[(table.startIndex + offset)..<(table.startIndex + offset + size)]
                result.styles[istd] = Self.style(in: record, baseSize: baseSize)
            }
            offset += size
        }
        return result
    }

    /// Одна запись таблицы стилей.
    private static func style(in record: Data, baseSize: Int) -> DocStyleTable.Style {
        var style = DocStyleTable.Style()
        style.sti = Int(CFBContainerReader.u16(record, 0) & 0x0FFF)
        let second = CFBContainerReader.u16(record, 2)
        let kind = Int(second & 0x000F)
        let base = Int((second >> 4) & 0x0FFF)
        // 0x0FFF — «ни от кого не унаследован»; ссылка на себя тоже бывает.
        style.base = base != 0x0FFF ? base : nil
        let upxCount = Int(CFBContainerReader.u16(record, 4) & 0x000F)

        // Имя: длина в знаках, потом сами знаки и завершающий ноль.
        var offset = baseSize
        let length = Int(CFBContainerReader.u16(record, offset))
        offset += 2
        guard length >= 0, offset + length * 2 + 2 <= record.count else { return style }
        style.name = String(decoding: (0..<length).map { CFBContainerReader.u16(record, offset + $0 * 2) }, as: UTF16.self)
        offset += length * 2 + 2

        // Дальше — наборы свойств: у абзацного стиля первым идёт абзацный
        // (с уровнем структуры), вторым — знаковый (с начертанием и кеглем).
        for index in 0..<max(0, min(upxCount, 2)) {
            guard offset + 2 <= record.count else { return style }
            let size = Int(CFBContainerReader.u16(record, offset))
            offset += 2
            guard size > 0, offset + size <= record.count else { return style }
            let isParagraphProperties = kind == 1 && index == 0
            // У абзацного набора первые два байта — номер стиля, а не свойство.
            let start = isParagraphProperties ? offset + 2 : offset
            if start < offset + size {
                let grpprl = record[(record.startIndex + start)..<(record.startIndex + offset + size)]
                forEachSprm(grpprl) { code, value in
                    switch Sprm(rawValue: code) {
                    case .paragraphOutline:
                        let level = Int(CFBContainerReader.byte(value, 0))
                        if level <= 8 { style.outline = level }
                    case .characterBold:
                        style.isBold = CFBContainerReader.byte(value, 0) == 1
                    case .characterSize:
                        style.halfPoints = Int(CFBContainerReader.u16(value, 0))
                    default: break
                    }
                }
            }
            offset += size + (size % 2)
        }
        return style
    }
}
