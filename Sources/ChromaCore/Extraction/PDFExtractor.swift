import Foundation
import PDFKit
import UniformTypeIdentifiers

/// PDF through PDFKit.
///
/// Page by page: the whole text of a document is never assembled twice, and the
/// page boundaries collected on the way are what let a chunk say which page it
/// came from.
public struct PDFExtractor: DocumentTextExtractor {
    public let id = "pdfkit"
    public let version = 1

    /// Below this many characters per page on average, a PDF is a picture of
    /// text rather than an empty document — the distinction decides whether the
    /// user is told «turn on OCR» or «there is nothing here».
    public static let scanCharactersPerPage = 20

    public init() {}

    public func canHandle(_ type: UTType) -> Bool { type.conforms(to: .pdf) }

    /// Opens a locked document with the password the user gave, if there is one.
    ///
    /// Three outcomes, and they are deliberately three: no password to try is
    /// «дайте пароль», a password that fails is «этот пароль не подошёл», and
    /// the file that was never locked needs nothing. One error for the first two
    /// would send the user back to a dialog to retype what they already typed.
    static func unlockIfNeeded(_ document: PDFDocument, password: String?) throws {
        guard document.isLocked else { return }
        guard let password, !password.isEmpty else { throw ExtractionError.passwordProtected }
        guard document.unlock(withPassword: password) else { throw ExtractionError.wrongPassword }
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.corrupted(String(localized: "PDF не открывается"))
        }
        // Checked before any attempt to read, as requires: asking PDFKit
        // for the text of a locked document returns nothing, which would be
        // reported as «no text layer» and send the user looking for OCR.
        try Self.unlockIfNeeded(document, password: options.password)

        var text = ""
        var pageStarts: [Int] = []
        for index in 0..<document.pageCount {
            let trimmed = (document.page(at: index)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // An empty page still gets an offset, or every page after it
                // would be numbered one too low.
                pageStarts.append(text.count)
                continue
            }
            if !text.isEmpty { text += "\n\n" }
            // **After** the separator, not before: the offset has to be where
            // this page's text actually begins. Recorded a line earlier, it
            // pointed at the tail of the previous page — which put the last two
            // characters of every page onto the next one, and made the first
            // line of a Keynote slide come out as the end of the slide before.
            pageStarts.append(text.count)
            text += trimmed
        }

        // Only trimmed page text is appended, and nothing is appended for an
        // empty page, so `text` never starts with whitespace — `sanitized` can
        // only trim the tail, and the page offsets collected above stay valid.
        guard let plainText = PlainTextExtractor.sanitized(text) else {
            let perPage = document.pageCount > 0 ? text.count / document.pageCount : 0
            throw ExtractionError.noTextLayer(
                looksLikeScan: document.pageCount > 0 && perPage < Self.scanCharactersPerPage
            )
        }

        let (structure, source) = outline(of: document, in: plainText, pageStarts: pageStarts)

        var warnings: [ExtractionWarning] = []
        switch source {
        case .outline: break
        case .heuristic: warnings.append(.structureIsHeuristic)
        default: warnings.append(.noStructure)
        }

        return ExtractedDocument(
            plainText: plainText,
            structure: structure,
            pageCount: document.pageCount,
            pageStarts: pageStarts,
            warnings: warnings,
            structureSource: source,
            containerFormat: "pdf",
            extractorID: id,
            extractorVersion: version,
            documentMetadata: options.includeDocumentMetadata ? metadata(of: document) : [:]
        )
    }

    // MARK: - Structure

    /// The table of contents, where the document has one.
    ///
    /// A real outline gives both the title and the page, and the page is what
    /// anchors a heading in the text: PDFKit's outline destinations point at a
    /// page, not at a character offset, so the start of that page is the best
    /// honest answer for where the section begins.
    private func outline(
        of document: PDFDocument,
        in text: String,
        pageStarts: [Int]
    ) -> ([DocumentNode], StructureSource) {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else {
            return ([], .none)
        }

        var nodes: [DocumentNode] = []
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty,
                   let page = child.destination?.page,
                   let pageIndex = document.index(for: page) as Int?,
                   pageIndex >= 0, pageIndex < pageStarts.count {
                    nodes.append(DocumentNode(
                        level: level,
                        title: title,
                        start: pageStarts[pageIndex],
                        pageNumber: pageIndex + 1
                    ))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 1)

        guard !nodes.isEmpty else { return ([], .none) }
        // Two headings on one page arrive with the same offset; keeping the
        // document order matters more than the offsets being distinct.
        return (nodes.sorted { ($0.start, $0.level) < ($1.start, $1.level) }, .outline)
    }

    private func metadata(of document: PDFDocument) -> [String: String] {
        var result: [String: String] = [:]
        guard let attributes = document.documentAttributes else { return result }
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            result["document_title"] = title
        }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            result["document_author"] = author
        }
        if let created = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            result["document_created"] = ISO8601DateFormatter().string(from: created)
        }
        return result
    }
}
