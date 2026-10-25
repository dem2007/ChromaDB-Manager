import Foundation

/// Знаки, которые в файле есть, а в тексте для поиска только мешают.
///
/// **Что было.** Текст уходил в базу таким, каким его отдал формат. На 91
/// документе корпуса:
/// - 7004 неразрывных пробела в 21 файле — фраза «от 5 мая», набранная
///   обычным пробелом, не совпадала с текстом, где пробел неразрывный;
/// - 346 знаков из частной области Юникода в 10 файлах — так PDF и Word
///   отдают символы шрифтов Symbol и Wingdings: `\u{F0B7}` вместо «•»,
///   `\u{F02D}` вместо «−», `\u{F03D}` вместо «=». Пункт списка с таким
///   маркером не узнавался пунктом, а «≤» в формуле читался служебным знаком;
/// - мягкие переносы и узкие пробелы.
///
/// **Как.** Замены — знак на знак, поэтому смещения в тексте (страницы,
/// разделы, ссылки) остаются верными. Мягкий перенос и знаки нулевой ширины
/// удаляются, и смещения документа пересчитываются (`normalized(_:)`).
public enum TextNormalization {
    /// Знак, каким его стоит видеть в тексте, или `nil` — знак удаляется.
    /// Возвращает сам знак, если менять нечего.
    /// - Parameter font: шрифт знака, если он известен: у знака
    ///   частной области от шрифта зависит, что это — буква Symbol или
    ///   маркер Wingdings.
    static func replacement(for character: Character, font: String? = nil) -> Character? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            // Буква с отдельным диакритическим знаком («и» + «̆») — одна и та
            // же буква, записанная иначе; приводится к составной форме.
            let composed = String(character).precomposedStringWithCanonicalMapping
            return composed.count == 1 ? composed.first : character
        }
        switch scalar.value {
        case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return " "
        case 0x00AD, 0x200B, 0x2060, 0xFEFF:
            return nil
        case 0x2011:
            // Неразрывный дефис: «44‑ФЗ» должно находиться по «44-ФЗ».
            return "-"
        case 0xF020...0xF0FF:
            return symbolCharacter(UInt8(scalar.value - 0xF000), font: font) ?? character
        default:
            return character
        }
    }

    /// Строка с заменёнными и удалёнными знаками.
    public static func normalized(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: needsWork) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            if let replaced = replacement(for: character) { result.append(replaced) }
        }
        return result
    }

    /// То же, со шрифтами знаков частной области.
    /// - Parameter fonts: шрифт знака по его смещению в UTF-16.
    static func normalized(_ text: String, fonts: [Int: String]) -> String {
        guard !fonts.isEmpty else { return normalized(text) }
        guard text.unicodeScalars.contains(where: needsWork) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var offset = 0
        for character in text {
            if let replaced = replacement(for: character, font: fonts[offset]) { result.append(replaced) }
            offset += character.utf16.count
        }
        return result
    }

    /// Знак частной области, который читается по-разному в Symbol и Wingdings.
    static func isSymbolFontCode(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && (0xF020...0xF0FF).contains(character.unicodeScalars.first!.value)
    }

    /// Документ с нормализованным текстом и пересчитанными смещениями.
    public static func normalized(_ document: ExtractedDocument) -> ExtractedDocument {
        let text = document.plainText
        guard text.unicodeScalars.contains(where: needsWork) else { return document }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        /// Места удалённых знаков в исходном тексте, по возрастанию.
        var removed: [Int] = []
        for (offset, character) in text.enumerated() {
            if let replaced = replacement(for: character) {
                result.append(replaced)
            } else {
                removed.append(offset)
            }
        }
        var normalized = document
        normalized.plainText = result
        guard !removed.isEmpty else { return normalized }

        /// Новое место знака: минус удалённые до него.
        func shifted(_ offset: Int) -> Int {
            var low = 0
            var high = removed.count
            while low < high {
                let middle = (low + high) / 2
                if removed[middle] < offset { low = middle + 1 } else { high = middle }
            }
            return offset - low
        }
        normalized.structure = document.structure.map {
            DocumentNode(level: $0.level, title: $0.title, start: shifted($0.start), pageNumber: $0.pageNumber)
        }
        normalized.pageStarts = document.pageStarts.map(shifted)
        normalized.parts = document.parts.map {
            DocumentPart(kind: $0.kind, index: $0.index, id: $0.id, start: shifted($0.start))
        }
        normalized.links = document.links.map { DocumentLink(url: $0.url, start: shifted($0.start)) }
        normalized.pagedTextEnd = document.pagedTextEnd.map(shifted)
        return normalized
    }

    /// Есть ли в знаке что нормализовать — дешёвая проверка перед проходом.
    static func needsWork(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00A0, 0x00AD, 0x2000...0x200B, 0x2011, 0x202F, 0x205F, 0x2060, 0x3000, 0xFEFF, 0xF020...0xF0FF:
            return true
        default:
            return scalar.properties.generalCategory == .nonspacingMark
        }
    }

    // MARK: - Символьные шрифты

    /// Знак символьного шрифта по его коду в шрифте.
    ///
    /// Word и PDF пишут такие знаки кодом шрифта, сдвинутым в частную
    /// область (`F000` + код). Шрифт известен только у `w:sym` в Word; у
    /// знака в тексте его нет, и тогда код читается по таблице Symbol —
    /// так набраны маркеры и формулы в корпусе (`F0B7` «•», `F02D` «−»,
    /// `F0A3` «≤»). Исключение — `A7`: в Symbol это «♣», но в документах
    /// это почти всегда маркер Wingdings «▪».
    public static func symbolCharacter(_ code: UInt8, font: String?) -> Character? {
        let lower = font?.lowercased() ?? ""
        if lower.hasPrefix("wingdings") || lower.hasPrefix("webdings") {
            return wingdings[code] ?? "•"
        }
        if font == nil, code == 0xA7 { return "▪" }
        return symbol[code]
    }

    /// Шрифт Symbol: латиница на месте греческих букв и математические знаки.
    static let symbol: [UInt8: Character] = {
        var table: [UInt8: Character] = [:]
        for code in UInt8(0x20)...UInt8(0x7E) {
            table[code] = Character(UnicodeScalar(code))
        }
        let greekUpper = Array("ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ")
        let greekLower = Array("αβχδεφγηιϕκλμνοπθρστυϖωξψζ")
        for (index, letter) in greekUpper.enumerated() { table[0x41 + UInt8(index)] = letter }
        for (index, letter) in greekLower.enumerated() { table[0x61 + UInt8(index)] = letter }
        let special: [UInt8: Character] = [
            0x22: "∀", 0x24: "∃", 0x27: "∋", 0x2A: "*", 0x2D: "−", 0x40: "≅", 0x5C: "∴", 0x5E: "⊥",
            0x60: "‾", 0x7E: "∼", 0xA1: "ϒ", 0xA2: "′", 0xA3: "≤", 0xA4: "⁄", 0xA5: "∞", 0xA6: "ƒ",
            0xA7: "♣", 0xA8: "♦", 0xA9: "♥", 0xAA: "♠", 0xAB: "↔", 0xAC: "←", 0xAD: "↑", 0xAE: "→",
            0xAF: "↓", 0xB0: "°", 0xB1: "±", 0xB2: "″", 0xB3: "≥", 0xB4: "×", 0xB5: "∝", 0xB6: "∂",
            0xB7: "•", 0xB8: "÷", 0xB9: "≠", 0xBA: "≡", 0xBB: "≈", 0xBC: "…", 0xBF: "↵", 0xC0: "ℵ",
            0xC4: "⊗", 0xC5: "⊕", 0xC6: "∅", 0xC7: "∩", 0xC8: "∪", 0xC9: "⊃", 0xCA: "⊇", 0xCB: "⊄",
            0xCC: "⊂", 0xCD: "⊆", 0xCE: "∈", 0xCF: "∉", 0xD0: "∠", 0xD1: "∇", 0xD2: "®", 0xD3: "©",
            0xD4: "™", 0xD5: "∏", 0xD6: "√", 0xD7: "⋅", 0xD8: "¬", 0xD9: "∧", 0xDA: "∨", 0xDB: "⇔",
            0xDC: "⇐", 0xDD: "⇑", 0xDE: "⇒", 0xDF: "⇓", 0xE0: "◊", 0xE1: "〈", 0xE5: "∑", 0xF1: "〉",
            0xF2: "∫",
        ]
        table.merge(special) { _, new in new }
        return table
    }()

    /// Wingdings — только то, что ставят маркерами и стрелками; прочее
    /// читается маркером «•»: картинка из шрифта смысла тексту не добавляет,
    /// а место пункта списка должно остаться.
    static let wingdings: [UInt8: Character] = [
        0x6C: "●", 0x6E: "■", 0x6F: "□", 0x71: "❑", 0x75: "◆", 0x76: "❖", 0x9F: "•", 0xA1: "○",
        0xA7: "▪", 0xA8: "◻", 0xD8: "➢", 0xDF: "←", 0xE0: "→", 0xE1: "↑", 0xE2: "↓", 0xE8: "→",
        0xF0: "⇨", 0xFB: "✗", 0xFC: "✓", 0xFD: "☒", 0xFE: "☑",
    ]
}
