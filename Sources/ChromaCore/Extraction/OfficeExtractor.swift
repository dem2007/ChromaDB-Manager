import Foundation
import AppKit
import UniformTypeIdentifiers

/// Word, RTF and OpenDocument through `NSAttributedString`.
///
/// The system already reads all four formats; what this adds is turning what it
/// gives back — fonts, paragraph styles, text blocks — into the structure and
/// warnings the rest of the app works with.
///
/// **On the main actor**, as requires: the importers behind `.html` and
/// `.officeOpenXML` are built on WebKit and are documented as needing the main
/// thread. Measured on this macOS they also work off it (see DECISIONS,
/// but «worked once» is not a promise, and the cost of obeying is a few
/// milliseconds of main-thread time per file.
public struct OfficeExtractor: DocumentTextExtractor {
    public let id = "office"
    /// 2 — comments, footnotes and tracked changes are detected through the ZIP
    /// container (4.5) and warned about. The text does not change; the warning
    /// in the chunk metadata does, and turns that into an offer to
    /// re-extract rather than into work.
    public let version = 2

    /// A paragraph this much larger than the body is a heading.
    static let headingSizeRatio: CGFloat = 1.15
    /// Longer than this and it is a paragraph that happens to be bold, not a
    /// heading. Headings are short — that is most of what makes them headings.
    static let headingLengthLimit = 120

    public init() {}

    public func canHandle(_ type: UTType) -> Bool {
        Self.documentType(for: type) != nil
    }

    /// Which importer the system should use. Chosen by `UTType` rather than by
    /// extension, and stated explicitly rather than left to the importer to
    /// guess: `.docx` renamed to `.doc` is still a `.docx`.
    static func documentType(for type: UTType) -> NSAttributedString.DocumentType? {
        if type.conforms(to: UTType("org.openxmlformats.wordprocessingml.document") ?? .data) {
            return .officeOpenXML
        }
        if type.conforms(to: UTType("org.oasis-open.opendocument.text") ?? .data) {
            return .openDocument
        }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return .rtf }
        if type.conforms(to: UTType("com.microsoft.word.doc") ?? .data) { return .docFormat }
        return nil
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        guard let type = ExtractorRegistry.type(of: url), let documentType = Self.documentType(for: type) else {
            throw ExtractionError.unsupportedFormat(url.pathExtension)
        }

        let parsed = try await Self.parse(url: url, documentType: documentType)
        let paragraphs = Self.paragraphs(of: parsed.text)
        guard let plainText = PlainTextExtractor.sanitized(Self.render(paragraphs)) else {
            throw ExtractionError.empty
        }

        let (structure, source) = Self.structure(of: paragraphs, in: plainText)
        var warnings: [ExtractionWarning] = []
        switch source {
        case .heuristic: warnings.append(.structureIsHeuristic)
        default: warnings.append(.noStructure)
        }
        let hasTables = paragraphs.contains { $0.table != nil }
        if hasTables { warnings.append(.tablesFlattened) }
        // Only the two ZIP-based formats: `.rtf` and `.doc` are not containers,
        // and there is nowhere in them to look.
        let isContainer = documentType == .officeOpenXML || documentType == .openDocument
        if isContainer, Self.containsCommentsOrRevisions(at: url) { warnings.append(.commentsSkipped) }

        return ExtractedDocument(
            plainText: plainText,
            structure: structure,
            warnings: warnings,
            structureSource: source,
            containerFormat: type.preferredFilenameExtension ?? url.pathExtension.lowercased(),
            extractorID: id,
            extractorVersion: version,
            hasTables: hasTables,
            documentMetadata: options.includeDocumentMetadata ? parsed.metadata : [:]
        )
    }

    // MARK: - Reading

    private struct Parsed {
        let text: NSAttributedString
        let metadata: [String: String]
    }

    @MainActor
    private static func parse(url: URL, documentType: NSAttributedString.DocumentType) throws -> Parsed {
        var attributes: NSDictionary?
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        do {
            let text = try NSAttributedString(url: url, options: options, documentAttributes: &attributes)
            return Parsed(text: text, metadata: metadata(from: attributes as? [String: Any] ?? [:]))
        } catch {
            // Never a silent skip: the file lands in «требуют решения»
            // with the reason the system gave.
            throw ExtractionError.corrupted(error.localizedDescription)
        }
    }

    private static func metadata(from attributes: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        if let title = attributes[NSAttributedString.DocumentAttributeKey.title.rawValue] as? String, !title.isEmpty {
            result["document_title"] = title
        }
        if let author = attributes[NSAttributedString.DocumentAttributeKey.author.rawValue] as? String, !author.isEmpty {
            result["document_author"] = author
        }
        if let created = attributes[NSAttributedString.DocumentAttributeKey.creationTime.rawValue] as? Date {
            result["document_created"] = ISO8601DateFormatter().string(from: created)
        }
        return result
    }

    // MARK: - What the importer does not show

    /// Comments, footnotes and tracked changes.
    ///
    /// `NSAttributedString` shows none of them — not as text, not as a flag —
    /// so until there was a way into the container there was nothing to warn
    /// about, and warning every office file unconditionally would have taught
    /// the user to ignore it. `.docx` and `.odt` are ZIP archives, and the parts
    /// that hold this are named by the standards.
    ///
    /// A failure to open the container is not an error here: the document was
    /// already read, and the worst case is a warning that is not shown.
    static func containsCommentsOrRevisions(at url: URL) -> Bool {
        guard let reader = try? ZIPContainerReader(url: url) else { return false }

        // Word: separate parts. Empty ones are written by some producers, so a
        // part that exists but holds nothing does not count.
        for part in ["word/comments.xml", "word/footnotes.xml", "word/endnotes.xml"] {
            if let entry = reader.entry(at: part), entry.uncompressedSize > 512 { return true }
        }
        // Tracked changes live inside the document itself, as do OpenDocument's
        // annotations — a substring is enough to notice them.
        for (part, markers) in [
            ("word/document.xml", ["<w:ins ", "<w:del ", "<w:commentRangeStart"]),
            ("content.xml", ["<office:annotation", "<text:tracked-changes", "<text:note "]),
        ] {
            guard let data = try? reader.read(part), let xml = String(data: data, encoding: .utf8) else { continue }
            if markers.contains(where: { xml.contains($0) }) { return true }
        }
        return false
    }

    // MARK: - Paragraphs

    struct Paragraph {
        var text: String
        var size: CGFloat
        var isBold: Bool
        /// Set when the paragraph is a table cell: which table, and where in it.
        var table: (id: ObjectIdentifier, row: Int, column: Int)?
    }

    static func paragraphs(of attributed: NSAttributedString) -> [Paragraph] {
        var result: [Paragraph] = []
        let string = attributed.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs]) { piece, range, _, _ in
            let text = (piece ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, range.length > 0 else { return }
            let attributes = attributed.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let block = (attributes[.paragraphStyle] as? NSParagraphStyle)?
                .textBlocks.compactMap { $0 as? NSTextTableBlock }.first
            result.append(Paragraph(
                text: text,
                size: font?.pointSize ?? 12,
                isBold: font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                table: block.map { (ObjectIdentifier($0.table), $0.startingRow, $0.startingColumn) }
            ))
        }
        return result
    }

    /// Paragraphs back into text, with tables flattened.
    ///
    /// Cells joined by tabs and rows by newlines — rebuilding table structure is
    /// explicitly out of scope, and a table read as prose is worse than a table
    /// read as a grid of words.
    static func render(_ paragraphs: [Paragraph]) -> String {
        var lines: [String] = []
        var index = 0
        while index < paragraphs.count {
            guard let table = paragraphs[index].table else {
                lines.append(paragraphs[index].text)
                index += 1
                continue
            }
            var cells: [(row: Int, column: Int, text: String)] = []
            while index < paragraphs.count, let current = paragraphs[index].table, current.id == table.id {
                cells.append((current.row, current.column, paragraphs[index].text))
                index += 1
            }
            let rows = Dictionary(grouping: cells, by: \.row).sorted { $0.key < $1.key }
            for (_, row) in rows {
                lines.append(row.sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t"))
            }
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Structure

    /// Headings by size and weight.
    ///
    /// The style-name branch the spec allows first is not reachable: neither the
    /// Word nor the ODT importer puts a paragraph style name into the attributes
    /// on this system — only `NSFont` and `NSParagraphStyle` come back.
    /// So the structure is always a guess, and always says so.
    static func structure(of paragraphs: [Paragraph], in text: String) -> ([DocumentNode], StructureSource) {
        let body = bodySize(of: paragraphs)
        var headings: [(paragraph: Paragraph, size: CGFloat)] = []
        for paragraph in paragraphs where paragraph.table == nil {
            guard paragraph.text.count <= headingLengthLimit else { continue }
            let larger = paragraph.size >= body * headingSizeRatio
            let emphasised = paragraph.isBold && paragraph.size >= body
            guard larger || emphasised else { continue }
            headings.append((paragraph, paragraph.size))
        }
        guard !headings.isEmpty else { return ([], .none) }

        // Bigger heading, shallower level. Bold-at-body-size sorts below every
        // enlarged heading, which is what a document that uses both looks like.
        let sizes = Array(Set(headings.map(\.size))).sorted(by: >)
        let level = Dictionary(uniqueKeysWithValues: sizes.enumerated().map { ($0.element, $0.offset + 1) })

        var nodes: [DocumentNode] = []
        var searchFrom = text.startIndex
        for heading in headings {
            guard let range = text.range(of: heading.paragraph.text, range: searchFrom..<text.endIndex) else { continue }
            nodes.append(DocumentNode(
                level: level[heading.size] ?? 1,
                title: heading.paragraph.text,
                start: text.distance(from: text.startIndex, to: range.lowerBound)
            ))
            searchFrom = range.upperBound
        }
        return nodes.isEmpty ? ([], .none) : (nodes, .heuristic)
    }

    /// The size most of the text is set in, weighted by how much text that is —
    /// a document with one huge title is still a 12-point document.
    static func bodySize(of paragraphs: [Paragraph]) -> CGFloat {
        var weight: [CGFloat: Int] = [:]
        for paragraph in paragraphs {
            weight[paragraph.size, default: 0] += paragraph.text.count
        }
        return weight.max { $0.value < $1.value }?.key ?? 12
    }
}
