import Foundation

/// Where a chunk sits in the document it came from.
public struct ChunkPlacement: Hashable, Sendable {
    /// Character offset in `plainText`.
    public var start: Int
    public var pageNumber: Int?
    public var headingPath: String?
    /// The chapter or slide this chunk came from.
    public var part: DocumentPart?

    public init(start: Int, pageNumber: Int? = nil, headingPath: String? = nil, part: DocumentPart? = nil) {
        self.start = start
        self.pageNumber = pageNumber
        self.headingPath = headingPath
        self.part = part
    }

    /// Nothing to write into the chunk metadata.
    public var isEmpty: Bool { pageNumber == nil && headingPath == nil && part == nil }
}

/// Finds each chunk back in its source text, so `page_number` and
/// `heading_path` can be written for every strategy rather than only for
/// the two that happen to know their offsets.
///
/// By matching the text, not by trusting arithmetic: chunkers trim, join and
/// overlap, and a computed offset would drift silently. A chunk that cannot be
/// found verbatim — the LLM strategy is allowed to rewrite what it returns —
/// gets **no** placement at all. A missing page number is a gap; a wrong one is
/// a lie the user has no way to spot.
public enum ChunkLocator {
    /// Offsets keyed by `TextChunk.index`. Absent means «not found, say nothing».
    public static func offsets(of chunks: [TextChunk], in text: String) -> [Int: Int] {
        guard !text.isEmpty else { return [:] }

        // Hierarchical children live inside their parent, and a parent overlaps
        // the one before it — walking the whole list forward would send the
        // search past a boundary it still needs. Parents are located in order;
        // each child is then searched inside its own parent's span.
        let parents = chunks.filter { $0.parentIndex == nil }
        var result = locate(parents, in: text, from: 0, to: text.count)

        let children = Dictionary(grouping: chunks.filter { $0.parentIndex != nil }, by: { $0.parentIndex! })
        for (parentIndex, group) in children {
            guard let parentStart = result[parentIndex],
                  let parent = chunks.first(where: { $0.index == parentIndex }) else { continue }
            let located = locate(
                group.sorted { $0.index < $1.index },
                in: text,
                from: parentStart,
                to: min(text.count, parentStart + parent.text.count)
            )
            result.merge(located) { current, _ in current }
        }
        return result
    }

    /// Placement plus what the document says about that offset.
    public static func placements(of chunks: [TextChunk], in document: ExtractedDocument) -> [Int: ChunkPlacement] {
        let offsets = offsets(of: chunks, in: document.plainText)
        var result: [Int: ChunkPlacement] = [:]
        for (index, start) in offsets {
            let placement = ChunkPlacement(
                start: start,
                pageNumber: document.pageNumber(forCharacter: start),
                headingPath: document.headingPath(forCharacter: start),
                part: document.part(forCharacter: start)
            )
            guard !placement.isEmpty else { continue }
            result[index] = placement
        }
        return result
    }

    /// Chunks in document order, each searched from just after the previous one
    /// started — never from where it ended, because chunks overlap.
    private static func locate(_ chunks: [TextChunk], in text: String, from lower: Int, to upper: Int) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var cursor = lower
        for chunk in chunks {
            guard !chunk.text.isEmpty, cursor < upper else { continue }
            let searchStart = text.index(text.startIndex, offsetBy: cursor)
            let searchEnd = text.index(text.startIndex, offsetBy: upper)
            guard let found = text.range(of: chunk.text, range: searchStart..<searchEnd) else { continue }
            let offset = cursor + text.distance(from: searchStart, to: found.lowerBound)
            result[chunk.index] = offset
            cursor = offset + 1
        }
        return result
    }
}
