import Foundation

/// Cutting text along the outline an extractor found in it.
///
/// This is the join between stage 4 and the chunking strategies: a PDF gets cut
/// on its table of contents and a Word file on its heading styles through the
/// same code, because by this point both are just `[DocumentNode]` over one
/// string. Nothing here knows what a PDF is.
public enum DocumentStructureSections {
    /// Character ranges of `text`, cut at every node of level `<= splitLevel`.
    ///
    /// Deeper headings stay inside their section — splitting on level 2 keeps a
    /// 2.1 with its parent, exactly as the Markdown path already behaves.
    public static func ranges(in text: String, structure: [DocumentNode], splitLevel: Int) -> [Range<Int>] {
        let length = text.count
        guard length > 0, !structure.isEmpty else { return [] }

        var boundaries: [Int] = []
        for node in structure where node.level <= splitLevel {
            let start = min(node.start, length)
            // Two headings on one PDF page share an offset: both are
            // real, but there is only one place to cut.
            if boundaries.last != start { boundaries.append(start) }
        }
        boundaries.sort()
        guard !boundaries.isEmpty else { return [] }
        // Whatever stands before the first heading — a title page, an abstract,
        // front matter — is content, not padding to drop on the floor.
        if boundaries[0] != 0 { boundaries.insert(0, at: 0) }

        var result: [Range<Int>] = []
        for (index, start) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : length
            if end > start { result.append(start..<end) }
        }
        return joiningBareHeadings(result, in: text, structure: structure)
    }

    /// Раздел, в котором нет ничего, кроме своего заголовка, — начало
    /// следующего, а не кусок.
    ///
    /// «Раздел 2» и сразу «2.1 Общие положения» — две границы подряд, и
    /// между ними один заголовок. Отдельным куском он не находится поиском
    /// ни по чему, кроме своего названия, а у первого подраздела этого
    /// названия нет (замер). Заголовок уходит в начало
    /// следующего раздела: кусок остаётся вырезкой из текста, границы
    /// разделов не сдвигаются, а у первого подраздела появляется раздел,
    /// которому он принадлежит. Последний раздел текста не к чему
    /// приклеить — он остаётся как есть.
    static func joiningBareHeadings(
        _ ranges: [Range<Int>], in text: String, structure: [DocumentNode]
    ) -> [Range<Int>] {
        guard ranges.count > 1 else { return ranges }
        let titles = Dictionary(grouping: structure, by: \.start)
            .mapValues { nodes in nodes.map { compact($0.title) }.joined() }
        var result: [Range<Int>] = []
        var pendingStart: Int?
        // Разделы идут подряд: строка проходится один раз, от раздела к
        // разделу, а не индексируется от начала для каждого.
        var cursor = text.startIndex
        var cursorOffset = 0
        for (position, range) in ranges.enumerated() {
            let start = pendingStart ?? range.lowerBound
            pendingStart = nil
            let lower = text.index(cursor, offsetBy: range.lowerBound - cursorOffset)
            let upper = text.index(lower, offsetBy: range.count)
            cursor = upper
            cursorOffset = range.upperBound
            // Голым может быть только раздел не длиннее своего заголовка
            // с пробелами и переносами — длинный и сжимать незачем.
            if position < ranges.count - 1, let title = titles[range.lowerBound], !title.isEmpty,
               range.count <= title.count * 2 + 16 {
                let body = compact(String(text[lower..<upper]))
                if !body.isEmpty, title.hasPrefix(body) {
                    pendingStart = start
                    continue
                }
            }
            result.append(start..<range.upperBound)
        }
        return result
    }

    /// Текст без пробелов и переводов строк — заголовок в тексте и в оглавлении
    /// разбит на строки по-разному.
    private static func compact(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// The same ranges as text, trimmed, with empty sections dropped.
    ///
    /// Only trimmed at the edges, so every section is still a verbatim substring
    /// of the document — which is what lets `ChunkLocator` find it again and give
    /// the chunk its page number.
    public static func sections(in text: String, structure: [DocumentNode], splitLevel: Int) -> [String] {
        let ranges = ranges(in: text, structure: structure, splitLevel: splitLevel)
        guard !ranges.isEmpty else { return [] }

        // The ranges are consecutive, so the string is walked once rather than
        // indexed from the start for every section.
        var result: [String] = []
        var cursor = text.startIndex
        var cursorOffset = 0
        for range in ranges {
            let start = text.index(cursor, offsetBy: range.lowerBound - cursorOffset)
            let end = text.index(start, offsetBy: range.count)
            let piece = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            cursor = end
            cursorOffset = range.upperBound
        }
        return result
    }

    /// The shallowest level the outline actually uses.
    ///
    /// Hierarchical takes its parent boundaries from here rather than from
    /// `splitHeaderLevel`: that parameter is not part of the hierarchical recipe
    /// digest, and a chunk boundary that no signature records is a collection
    /// that cannot tell it has become heterogeneous.
    public static func topLevel(of structure: [DocumentNode]) -> Int {
        structure.map(\.level).min() ?? 1
    }
}
