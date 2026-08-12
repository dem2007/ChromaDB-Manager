import Foundation

// MARK: - Document-based

/// Splits on the document's own structure: an outline the extractor found,
/// Markdown headings, HTML tags or function and class boundaries in code
///.
///
/// Deliberately not a parser. A heading regex, a tag scan and a set of
/// language-agnostic line heuristics cover the formats this app actually ingests;
/// anything a heuristic misses ends up as one bigger section, which the oversized
/// fallback then splits. That degrades gracefully — a real parser per language
/// would not, and would be a far bigger promise than it can keep.
///
/// Where the file arrived with a real `structure` — a PDF outline, EPUB nav,
/// `.docx` heading styles — that wins over every heuristic below: it is the
/// document saying where its own sections are, instead of us guessing from the
/// characters it happens to contain.
public struct DocumentBasedChunker: Chunking {
    public let configuration: ChunkingConfiguration
    public let fileExtension: String?
    public let structure: [DocumentNode]

    public init(configuration: ChunkingConfiguration, fileExtension: String? = nil, structure: [DocumentNode] = []) {
        self.configuration = configuration
        self.fileExtension = fileExtension
        self.structure = structure
    }

    public func chunks(from text: String) -> [TextChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Cut on the untrimmed text: the offsets in `structure` are counted from
        // the start of what the extractor produced, and trimming first would
        // shift every one of them.
        var sections = DocumentStructureSections.sections(
            in: text, structure: structure, splitLevel: configuration.splitHeaderLevel
        )
        if sections.isEmpty {
            let format = DocumentSourceFormat.resolved(configuration.sourceFormat, fileExtension: fileExtension)
            switch format {
            case .markdown, .auto: sections = markdownSections(trimmed)
            case .html: sections = htmlSections(trimmed)
            case .code: sections = codeSections(trimmed)
            }
        }

        let limit = configuration.maxSectionSizeInCharacters
        var result: [String] = []
        for section in sections {
            let piece = section.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if piece.count <= limit {
                result.append(piece)
            } else {
                result += split(oversized: piece, limit: limit)
            }
        }
        return result.enumerated().map { TextChunk(index: $0.offset, text: $0.element) }
    }

    private func split(oversized text: String, limit: Int) -> [String] {
        switch configuration.oversizedFallback {
        case .keep:
            return [text]
        case .fixed:
            return FixedSizeChunker(
                size: limit,
                overlap: configuration.overlapInCharacters(percent: configuration.overlapPercent, of: limit)
            ).chunks(from: text).map(\.text)
        case .recursive:
            return RecursiveChunker(
                size: limit,
                overlap: configuration.overlapInCharacters(percent: configuration.overlapPercent, of: limit),
                separators: configuration.separators
            ).chunks(from: text).map(\.text)
        }
    }

    // MARK: Markdown

    /// Starts a new section at every heading of the configured level or above, so
    /// splitting on `##` keeps an `###` subsection with its parent.
    func markdownSections(_ text: String) -> [String] {
        let level = max(1, min(configuration.splitHeaderLevel, 6))
        var sections: [String] = []
        var current: [String] = []
        var insideFence = false

        for line in text.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            // A `#` inside a fenced code block is a comment, not a heading.
            if stripped.hasPrefix("```") || stripped.hasPrefix("~~~") {
                insideFence.toggle()
                current.append(line)
                continue
            }
            if !insideFence, let headingLevel = Self.headingLevel(of: stripped), headingLevel <= level {
                if !current.isEmpty {
                    sections.append(current.joined(separator: "\n"))
                    current = []
                }
            }
            current.append(line)
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections
    }

    static func headingLevel(of line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        // "#tag" is not a heading; "# Title" is.
        guard rest.first == " " || rest.isEmpty else { return nil }
        return hashes
    }

    // MARK: HTML

    /// Cuts at the outermost occurrences of the configured tags. Nested tags of
    /// the same name stay inside their parent block — tracking depth is enough to
    /// get that right without pretending to parse HTML.
    func htmlSections(_ text: String) -> [String] {
        let tags = configuration.splitTags
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>/")) .lowercased() }
            .filter { !$0.isEmpty }
        guard !tags.isEmpty else { return [text] }

        let pattern = "</?(" + tags.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [text] }

        let nsText = text as NSString
        var sections: [String] = []
        var depth = 0
        var blockStart = 0
        var cursor = 0

        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            let token = nsText.substring(with: match.range)
            let isClosing = token.hasPrefix("</")

            if isClosing {
                depth = max(0, depth - 1)
                if depth == 0 {
                    let end = match.range.location + match.range.length
                    sections.append(nsText.substring(with: NSRange(location: blockStart, length: end - blockStart)))
                    cursor = end
                }
            } else {
                if depth == 0 {
                    // Text between blocks is content too, not padding to discard.
                    if match.range.location > cursor {
                        sections.append(nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                    }
                    blockStart = match.range.location
                }
                depth += 1
            }
        }
        if cursor < nsText.length {
            sections.append(nsText.substring(from: cursor))
        }
        return sections.isEmpty ? [text] : sections
    }

    // MARK: Code

    /// Starts a new section at a line that begins a top-level function or type.
    /// Language-agnostic on purpose: the app ingests whatever the user's folder
    /// holds, and per-language parsers are not on the table.
    func codeSections(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var sections: [String] = []
        var current: [String] = []

        for line in lines {
            if !current.isEmpty, isBoundary(line) {
                sections.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections
    }

    private func isBoundary(_ line: String) -> Bool {
        // Only declarations at the very start of a line: an indented `func` is a
        // method inside a type, and cutting there would orphan it from its type.
        guard let first = line.first, !first.isWhitespace else { return false }
        let stripped = line.trimmingCharacters(in: .whitespaces).lowercased()
        let words = stripped.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ":" }).map(String.init)
        guard !words.isEmpty else { return false }

        let functionKeywords: Set<String> = ["func", "def", "function", "fn", "sub", "proc"]
        let typeKeywords: Set<String> = ["class", "struct", "enum", "protocol", "interface", "extension", "actor", "trait", "impl", "type", "record"]
        let modifiers: Set<String> = ["public", "private", "internal", "fileprivate", "open", "static", "final", "async", "export", "default", "abstract", "sealed", "data", "const", "let", "var", "@objc", "override", "package", "protected", "suspend", "inline", "unsafe", "pub"]

        var wants: Set<String> = []
        switch configuration.codeSplitBy {
        case .functions: wants = functionKeywords
        case .classes: wants = typeKeywords
        case .both: wants = functionKeywords.union(typeKeywords)
        }

        for word in words {
            let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if wants.contains(token) { return true }
            // Skip leading modifiers, but stop at the first real identifier.
            if modifiers.contains(token) || token.hasPrefix("@") { continue }
            return false
        }
        return false
    }
}

// MARK: - Hierarchical

/// Big parent chunks plus small child chunks of the same text.
///
/// Both live in one collection and are told apart by `chunk_level`; a child
/// points at its parent through `parent_chunk_id`, which is what makes it
/// possible to retrieve a precise fragment and then show its context.
///
/// When the file brought a `structure`, the parents are its top-level sections
/// — a parent that is a chapter is worth far more as context than a
/// parent that is «the next 2000 characters».
public struct HierarchicalChunker: Chunking {
    public let configuration: ChunkingConfiguration
    public let structure: [DocumentNode]

    public init(configuration: ChunkingConfiguration, structure: [DocumentNode] = []) {
        self.configuration = configuration
        self.structure = structure
    }

    public func chunks(from text: String) -> [TextChunk] {
        let parentSize = configuration.parentSizeInCharacters
        let childSize = min(configuration.childSizeInCharacters, max(32, parentSize - 1))

        let parents = structuralParents(of: text, size: parentSize) ?? RecursiveChunker(
            size: parentSize,
            overlap: configuration.overlapInCharacters(percent: configuration.parentOverlapPercent, of: parentSize),
            separators: configuration.separators
        ).chunks(from: text)
        guard !parents.isEmpty else { return [] }

        // A single level means "no children" — the parameter is honoured rather
        // than silently producing the two-level result anyway.
        guard configuration.levels > 1 else {
            return parents.enumerated().map { TextChunk(index: $0.offset, text: $0.element.text, level: 1) }
        }

        var result: [TextChunk] = []
        for parent in parents {
            let parentIndex = result.count
            result.append(TextChunk(index: parentIndex, text: parent.text, level: 1))

            let children = RecursiveChunker(
                size: childSize,
                overlap: configuration.overlapInCharacters(percent: configuration.childOverlapPercent, of: childSize),
                separators: configuration.separators
            ).chunks(from: parent.text)

            for child in children {
                result.append(TextChunk(
                    index: result.count,
                    text: child.text,
                    level: 0,
                    parentIndex: parentIndex
                ))
            }
        }
        return result
    }

    /// Top-level sections as parents, or `nil` when the file has no structure.
    ///
    /// The size limit still applies inside a section: a parent chunk is embedded
    /// like any other, and a forty-page chapter handed to the model whole would
    /// be refused for length. So a section longer than the parent size is
    /// split — but only within its own boundaries, never across a heading.
    /// Sections shorter than the limit are *not* glued together: merging two
    /// chapters into one parent would undo the point of using the structure.
    private func structuralParents(of text: String, size: Int) -> [TextChunk]? {
        let sections = DocumentStructureSections.sections(
            in: text,
            structure: structure,
            splitLevel: DocumentStructureSections.topLevel(of: structure)
        )
        guard !sections.isEmpty else { return nil }

        let overlap = configuration.overlapInCharacters(percent: configuration.parentOverlapPercent, of: size)
        var result: [TextChunk] = []
        for section in sections {
            if section.count <= size {
                result.append(TextChunk(index: result.count, text: section))
                continue
            }
            let pieces = RecursiveChunker(size: size, overlap: overlap, separators: configuration.separators)
                .chunks(from: section)
            for piece in pieces {
                result.append(TextChunk(index: result.count, text: piece.text))
            }
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Adaptive

/// Chunk size follows how dense the text is — heuristics only.
///
/// The spec's "light classifier model" variant is deliberately absent: it is not
/// defined operationally and would tie chunking to an arbitrary model. Dense text
/// (long sentences, many numbers and punctuation marks — tables, references,
/// code-like prose) gets smaller chunks; airy text gets bigger ones.
public struct AdaptiveChunker: Chunking {
    public let configuration: ChunkingConfiguration

    public init(configuration: ChunkingConfiguration) {
        self.configuration = configuration
    }

    public func chunks(from text: String) -> [TextChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Blocks are sized independently, so a folder mixing tables and prose
        // does not have to compromise on one size for the whole file.
        let blocks = trimmed.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [TextChunk] = []

        for block in blocks.isEmpty ? [trimmed] : blocks {
            let size = targetSize(for: block)
            let pieces = RecursiveChunker(
                size: size,
                overlap: configuration.overlapInCharacters(percent: configuration.overlapPercent, of: size),
                separators: configuration.separators
            ).chunks(from: block)
            for piece in pieces {
                result.append(TextChunk(index: result.count, text: piece.text))
            }
        }
        return result
    }

    /// Density in 0…1, then the size moves from base towards min (dense) or max
    /// (sparse), scaled by `sensitivity`.
    func targetSize(for text: String) -> Int {
        let base = configuration.baseSizeInCharacters
        let minimum = min(configuration.minSizeInCharacters, base)
        let maximum = max(configuration.maxSizeInCharacters, base)
        let sensitivity = max(0, min(configuration.sensitivity, 1))
        guard sensitivity > 0 else { return base }

        let density = Self.density(of: text)
        let size: Double
        if density >= 0.5 {
            let factor = (density - 0.5) * 2 * sensitivity
            size = Double(base) - Double(base - minimum) * factor
        } else {
            let factor = (0.5 - density) * 2 * sensitivity
            size = Double(base) + Double(maximum - base) * factor
        }
        return max(32, Int(size.rounded()))
    }

    /// 0 = airy prose, 1 = dense reference material.
    static func density(of text: String) -> Double {
        guard !text.isEmpty else { return 0.5 }
        let characters = Array(text)
        let total = Double(characters.count)

        let digits = Double(characters.filter { $0.isNumber }.count) / total
        let punctuation = Double(characters.filter { $0.isPunctuation || $0.isSymbol }.count) / total

        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let averageSentence = sentences.isEmpty ? total : total / Double(sentences.count)
        // ~120 characters per sentence reads as long-winded, ~20 as terse.
        let brevity = max(0, min(1, (120 - averageSentence) / 100))

        // Digits and punctuation dominate the signal; sentence brevity refines it.
        let score = digits * 2.5 + punctuation * 2.0 + brevity * 0.4
        return max(0, min(1, score))
    }
}
