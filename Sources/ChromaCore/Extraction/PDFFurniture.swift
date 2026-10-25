import Foundation

/// Повторяющиеся края страниц PDF — колонтитулы, штампы, номера страниц
///.
///
/// **Что было.** Договор, переданный через Диадок, несёт на каждой странице
/// штамп «Передан через Диадок <дата и время>», номер документа и «Страница
/// N из M». В корпусе такой штамп стоял в каждом восьмом куске PDF — и хуже
/// того, сшивка абзацев приклеивала его к последнему абзацу страницы:
/// конец предложения, а за ним сразу «Передан через Диадок…». В поиске такой кусок
/// находился по слову «Диадок», а в векторе нёс шум.
///
/// **Признак — повтор на краю.** Строка, которая стоит в первых или
/// последних строках страницы и повторяется так же на многих страницах, —
/// оформление, а не текст. Сравнивается без цифр и пробелов: номер страницы
/// и дата меняются, слова — нет. Строка из одних цифр («5», «— 12 —»)
/// считается номером страницы, если такие стоят на краю многих страниц.
/// Удаляется строка только на краю: в середине страницы та же фраза —
/// уже текст.
struct PDFFurniture {
    /// Сколько строк сверху и снизу страницы считаются краем. Снизу больше:
    /// штамп с номером документа и страницей — три-четыре строки.
    static let topLines = 3
    static let bottomLines = 6
    /// Повтор хотя бы на стольких страницах и на такой их доле.
    static let minimumPages = 3
    static let minimumShare = 0.3
    /// Короче этого (без цифр и пробелов) строка — не колонтитул, а слово,
    /// которое бывает на краю случайно: «Итого», «Да».
    static let minimumKey = 6
    static let pageNumberKey = "#"

    private let repeated: Set<String>
    /// Сравнивать набор букв, а не их порядок.
    private let unordered: Bool

    /// Строки у края листа на собранных страницах.
    ///
    /// Сравниваются **наборы** букв, а не строки: штамп и «Страница N из M»
    /// стоят на одной высоте внахлёст, и сборка по координатам перемешивает
    /// их буквы — «25.12.С20т2р4 а11н:18иGцMаT…». Порядок у каждой страницы
    /// свой, набор — один и тот же.
    init(margins: [[String]]) {
        unordered = true
        var counts: [String: Int] = [:]
        for lines in margins {
            for key in Set(lines.compactMap { Self.key($0, unordered: true) }) { counts[key, default: 0] += 1 }
        }
        let needed = max(Self.minimumPages, Int((Double(margins.count) * Self.minimumShare).rounded(.up)))
        repeated = Set(counts.filter { $0.value >= needed }.map(\.key))
    }

    /// - Parameter pages: исходный текст страниц, как его отдаёт PDFKit.
    init(pages: [String]) {
        unordered = false
        var counts: [String: Int] = [:]
        var withText = 0
        for page in pages {
            let lines = page.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            withText += 1
            for key in Set(Self.edges(of: lines).compactMap { Self.key($0) }) { counts[key, default: 0] += 1 }
        }
        let needed = max(Self.minimumPages, Int((Double(withText) * Self.minimumShare).rounded(.up)))
        repeated = Set(counts.filter { $0.value >= needed }.map(\.key))
    }

    var isEmpty: Bool { repeated.isEmpty }

    /// Повторяется ли строка на краях страниц — где бы она ни стояла.
    /// Решать, на краю ли она сейчас, — дело того, кто знает её место.
    func isRepeated(_ line: String) -> Bool {
        guard let key = Self.key(line.trimmingCharacters(in: .whitespaces), unordered: unordered) else { return false }
        return repeated.contains(key)
    }

    /// Ключ сравнения: буквы без цифр, пробелов и знаков. Строка из одних
    /// цифр и знаков — номер страницы.
    static func key(_ line: String, unordered: Bool = false) -> String? {
        let letters = String(line.lowercased().filter { $0.isLetter })
        if letters.isEmpty {
            return line.count <= 12 && line.contains(where: \.isNumber) ? pageNumberKey : nil
        }
        guard letters.count >= minimumKey else { return nil }
        return unordered ? String(letters.sorted()) : letters
    }

    private static func edges(of lines: [String]) -> ArraySlice<String> {
        guard lines.count > topLines + bottomLines else { return lines[...] }
        return lines.prefix(topLines) + lines.suffix(bottomLines)
    }

    /// Строки без оформления: удаляется только повтор на краю.
    func cleaned(_ lines: [String], seen: inout Set<String>) -> [String] {
        guard !repeated.isEmpty else { return lines }
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let edge = Set(filled.prefix(Self.topLines) + filled.suffix(Self.bottomLines))
        var result: [String] = []
        for index in lines.indices {
            if edge.contains(index), !first(lines[index], seen: &seen) { continue }
            result.append(lines[index])
        }
        return result
    }

    /// Ключ строки, если она — повторяющееся оформление.
    func repeatedKey(_ line: String) -> String? {
        guard let key = Self.key(line.trimmingCharacters(in: .whitespaces), unordered: unordered),
              repeated.contains(key) else { return nil }
        return key
    }

    /// Первое появление строки оформления в документе остаётся: подписанты
    /// внизу каждой страницы приложений и дата передачи через Диадок —
    /// содержание, и один раз в тексте им место. Уходят повторы.
    private func first(_ line: String, seen: inout Set<String>) -> Bool {
        guard let key = repeatedKey(line) else { return true }
        return seen.insert(key).inserted
    }

    /// Страница кусками без строк у края листа, повторяющихся по документу.
    func removing(
        _ margin: [String], from blocks: [TableGeometry.PageBlock], seen: inout Set<String>
    ) -> [TableGeometry.PageBlock] {
        var drop: Set<String> = []
        for line in margin where !first(line, seen: &seen) { drop.insert(line) }
        guard !drop.isEmpty else { return blocks }
        return blocks.compactMap { block in
            guard case .text(let lines) = block else { return block }
            let kept = lines.filter { !drop.contains($0) }
            return kept.isEmpty ? nil : .text(kept)
        }
    }

    /// То же для страницы, собранной кусками: краем считаются строки текста
    /// страницы целиком, таблицы не трогаются.
    func cleaned(_ blocks: [TableGeometry.PageBlock], seen: inout Set<String>) -> [TableGeometry.PageBlock] {
        guard !repeated.isEmpty else { return blocks }
        var all: [String] = []
        for case .text(let lines) in blocks { all += lines }
        let kept = cleaned(all, seen: &seen)
        guard kept.count != all.count else { return blocks }
        // Удалённые строки — по месту: проход по тем же строкам в том же
        // порядке, отмечая, какие остались.
        var keptIndex = 0
        var result: [TableGeometry.PageBlock] = []
        for block in blocks {
            guard case .text(let lines) = block else { result.append(block); continue }
            var survivors: [String] = []
            for line in lines where keptIndex < kept.count && kept[keptIndex] == line {
                survivors.append(line)
                keptIndex += 1
            }
            if !survivors.isEmpty { result.append(.text(survivors)) }
        }
        return result
    }
}
