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
        return result
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
