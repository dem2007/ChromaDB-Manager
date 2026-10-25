import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#endif

/// Заголовки PDF без закладок — по виду строки.
///
/// **Что было.** Структура PDF бралась только из закладок-оглавления. У
/// договоров и ТЗ их почти никогда нет, и 97 % кусков PDF в коллекции
/// не знали своего раздела: ни строки «Документ → Раздел» в векторе, ни
/// фильтра по `heading_path`. У Word догадка по кеглю и жирности есть давно
///, у PDF не было никакой.
///
/// **Как.** Кандидат — строка готового текста страницы одного из трёх видов:
/// - нумерованная: «2.1 Требования к системе», «5. ОТВЕТСТВЕННОСТЬ
///   СТОРОН» — уровень по числу частей номера;
/// - «Раздел 3», «Глава 2», «Статья 5», «Приложение 1» с названием или без —
///   первый уровень;
/// - строка прописными — первый уровень.
///
/// Кандидат становится заголовком, только если шрифт его начала на странице
/// **жирный или крупнее основного** (основной — кегль, которым набрана
/// большая часть текста). Пункт договора «1.1. Поставщик обязуется…»
/// нумерован так же, но набран основным шрифтом — и заголовком не станет.
///
/// **Чего не берёт.**
/// - строку оглавления (отточия, номер страницы в конце);
/// - строку длиннее 150 знаков и пункт-предложение (кончается точкой,
///   больше двенадцати слов);
/// - строку таблицы;
/// - строку, повторённую на трёх страницах и больше, — колонтитул;
/// - страницу без шрифтов (распознанный скан).
///
/// Меньше двух заголовков — не структура: один жирный номер на документ
/// скорее реквизит, чем раздел.
enum PDFHeadings {
    static let maximumLength = 150
    static let largerRatio: CGFloat = 1.15
    static let sentenceWords = 12

    /// Заголовки документа в порядке текста, или пусто.
    /// - Parameters:
    ///   - pages: текст каждой страницы, как он стоит в документе;
    ///   - pageStarts: смещение текста страницы в документе;
    ///   - skipped: страницы без своих шрифтов (распознанные).
    static func detect(
        in document: PDFDocument, pages: [String], pageStarts: [Int], skipped: Set<Int>
    ) -> [DocumentNode] {
        struct Candidate {
            let page: Int
            let offset: Int
            let title: String
            let level: Int
            let numbered: Bool
            /// Следующая строка страницы — продолжение заголовка, если он
            /// перенесён: «…ПРИ КАЗНАЧЕЙСКОМ СОПРОВОЖДЕНИИ» и «КОНТРАКТА».
            let next: String?
            /// Сколько букв и цифр страницы стоит до строки — по нему из
            /// нескольких вхождений строки выбирается её собственное. Только
            /// буквы и цифры: разметки таблиц (`|`, `| --- |`) в тексте
            /// страницы много, а в шрифтах PDF её нет, и по всем знакам
            /// место уезжало на каждой странице с таблицей.
            let compactOffset: Int
        }
        var candidates: [Candidate] = []
        var counts: [String: Int] = [:]
        for (index, text) in pages.enumerated() where !skipped.contains(index) && index < pageStarts.count {
            var offset = 0
            let lines = text.components(separatedBy: "\n")
            /// Строка, уже приклеенная к заголовку выше: своим она не бывает.
            var continuation: Int?
            var compactOffset = 0
            for (position, line) in lines.enumerated() {
                defer {
                    offset += line.count + 1
                    compactOffset += line.filter(FontMap.isCounted).count
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if continuation == position {
                    continuation = nil
                    if kind(of: trimmed)?.numbered != true { continue }
                }
                guard let (level, numbered) = kind(of: trimmed) else { continue }
                let lead = line.prefix { $0.isWhitespace }.count
                // Сшивка отделяет строки заголовка пустой строкой, как абзацы:
                // продолжение ищется через одну пустую.
                var nextPosition = position + 1
                if nextPosition < lines.count, lines[nextPosition].trimmingCharacters(in: .whitespaces).isEmpty {
                    nextPosition += 1
                }
                let following = nextPosition < lines.count
                    ? lines[nextPosition].trimmingCharacters(in: .whitespaces) : ""
                let next = isContinuation(following) ? following : nil
                continuation = next != nil ? nextPosition : nil
                candidates.append(Candidate(
                    page: index, offset: offset + lead, title: trimmed, level: level, numbered: numbered, next: next,
                    compactOffset: compactOffset
                ))
                counts[trimmed, default: 0] += 1
            }
        }
        guard candidates.count >= 2 else { return [] }

        // Основной кегль — по страницам с кандидатами и первым десяти.
        let pagesToRead = Set(candidates.map(\.page)).union(0..<min(10, document.pageCount))
        var fonts: [Int: FontMap] = [:]
        var weights: [CGFloat: Int] = [:]
        for index in pagesToRead.sorted() where !skipped.contains(index) {
            guard let page = document.page(at: index), let attributed = page.attributedString else { continue }
            fonts[index] = FontMap(attributed)
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                weights[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
            }
        }
        guard let body = weights.max(by: { $0.value < $1.value })?.key, body > 0 else { return [] }

        var nodes: [DocumentNode] = []
        for candidate in candidates where (counts[candidate.title] ?? 0) < 3 {
            guard let map = fonts[candidate.page],
                  let font = map.font(of: candidate.title, near: candidate.compactOffset) else { continue }
            let larger = font.pointSize >= body * largerRatio
            guard larger || isBold(font) else { continue }
            // Продолжение — тем же шрифтом, иначе это уже текст раздела.
            // Кегль — с допуском: у одной и той же строки, набранной в 14 пт,
            // PDFKit отдаёт и 13,98, и 14,02.
            var title = candidate.title
            let titleLength = candidate.title.filter(FontMap.isCounted).count
            if let next = candidate.next,
               let nextFont = map.font(of: next, near: candidate.compactOffset + titleLength),
               abs(nextFont.pointSize - font.pointSize) <= 0.5, isBold(nextFont) == isBold(font) {
                title += " " + next
            }
            nodes.append(DocumentNode(
                level: candidate.level,
                title: title,
                start: pageStarts[candidate.page] + candidate.offset,
                pageNumber: candidate.page + 1
            ))
        }
        guard nodes.count >= 2 else { return [] }
        // Уровни — с первого: документ, где номера начинаются с «1.1»,
        // не должен остаться без верхнего уровня.
        let top = nodes.map(\.level).min() ?? 1
        return nodes.map { DocumentNode(level: $0.level - top + 1, title: $0.title, start: $0.start, pageNumber: $0.pageNumber) }
    }

    /// Вид строки-кандидата: уровень и нумерована ли она, или `nil`.
    static func kind(of line: String) -> (level: Int, numbered: Bool)? {
        guard line.count >= 3, line.count <= maximumLength,
              !line.hasPrefix("|"), !isTableOfContents(line) else { return nil }
        let words = line.split(whereSeparator: \.isWhitespace)
        if line.hasSuffix("."), words.count > sentenceWords { return nil }
        if line.hasSuffix(";") || line.hasSuffix(",") { return nil }

        // «2.1 Требования», «5. ОТВЕТСТВЕННОСТЬ».
        if let first = words.first {
            let number = first.hasSuffix(".") ? first.dropLast() : first[...]
            let parts = number.split(separator: ".", omittingEmptySubsequences: false)
            if !parts.isEmpty, parts.count <= 4,
               parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }),
               words.count >= 2, let letter = words[1].first, letter.isUppercase {
                // Номер страницы в конце — строка оглавления.
                if let last = words.last, words.count > 2, last.allSatisfy(\.isNumber) { return nil }
                return (parts.count, true)
            }
        }
        // «Раздел 3», «Глава 2», «Статья 5», «Приложение 1».
        let lowered = line.lowercased()
        if ["раздел ", "глава ", "статья ", "приложение ", "часть "].contains(where: { lowered.hasPrefix($0) }),
           words.count >= 2, words[1].first?.isNumber == true || words[1].first?.isUppercase == true {
            return (1, true)
        }
        // Строка прописными.
        let letters = line.filter(\.isLetter)
        if letters.count >= 8, letters.allSatisfy({ $0.isUppercase }), words.count <= 14 {
            return (1, false)
        }
        return nil
    }

    /// Может ли строка быть хвостом перенесённого заголовка: короткая,
    /// прописными или со строчной буквы, без своего номера.
    static func isContinuation(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 100, !line.hasPrefix("|"), let first = line.first else { return false }
        if first.isLowercase { return !line.hasSuffix(".") }
        let letters = line.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isUppercase) && kind(of: line)?.numbered != true
    }

    static func isTableOfContents(_ line: String) -> Bool {
        line.contains("....") || line.contains("…..") || line.contains(". . . .") || line.contains("____")
    }

    /// Шрифты страницы и её знаки без пробелов — строка ищется по ним:
    /// сшивка меняет пробелы и переносы, а знаки оставляет.
    struct FontMap {
        let attributed: NSAttributedString
        let compact: String
        /// Место каждого знака `compact` в исходной строке, в UTF-16.
        let positions: [Int]
        /// Сколько букв и цифр стоит до каждого знака `compact` — мерило
        /// места, общее с текстом страницы (`isCounted`).
        let counted: [Int]

        /// Знак, по которому меряется место строки на странице.
        static func isCounted(_ character: Character) -> Bool {
            character.isLetter || character.isNumber
        }

        init(_ attributed: NSAttributedString) {
            self.attributed = attributed
            var compact = ""
            var positions: [Int] = []
            var counted: [Int] = []
            var offset = 0
            var letters = 0
            for character in attributed.string {
                if !character.isWhitespace {
                    compact.append(character)
                    positions.append(offset)
                    counted.append(letters)
                }
                if Self.isCounted(character) { letters += 1 }
                offset += character.utf16.count
            }
            self.compact = compact
            self.positions = positions
            self.counted = counted
        }

        /// Шрифт первой буквы строки, а не номера: номер раздела бывает
        /// набран иначе.
        ///
        /// Строка может стоять на странице не раз — заголовок «ОБЩИЕ
        /// ПОЛОЖЕНИЯ» и ссылка на него в тексте. Берётся вхождение, ближайшее
        /// к месту строки в тексте страницы (`near` — число букв
        /// и цифр до неё), а не первое: иначе шрифт брался у ссылки.
        func font(of title: String, near: Int? = nil) -> NSFont? {
            let letters = Array(title.filter { !$0.isWhitespace }.prefix(16))
            guard letters.count >= 3 else { return nil }
            let needle = String(letters)
            var best: Int?
            var searchStart = compact.startIndex
            var scanned = 0
            while let found = compact.range(of: needle, range: searchStart..<compact.endIndex) {
                scanned += compact.distance(from: searchStart, to: found.lowerBound)
                guard let target = near else { best = scanned; break }
                if let current = best,
                   abs(counted[current] - target) <= abs(counted[min(scanned, counted.count - 1)] - target) { break }
                best = scanned
                searchStart = compact.index(after: found.lowerBound)
                scanned += 1
            }
            guard let index = best else { return nil }
            let letter = letters.firstIndex(where: \.isLetter) ?? 0
            guard index + letter < positions.count else { return nil }
            return attributed.attribute(.font, at: positions[index + letter], effectiveRange: nil) as? NSFont
        }
    }

    static func isBold(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let name = font.fontName.lowercased()
        return ["bold", "semibold", "black", "heavy", "demi"].contains { name.contains($0) }
    }
}
