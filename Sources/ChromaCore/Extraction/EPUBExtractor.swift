import Foundation
import AppKit
import UniformTypeIdentifiers

/// EPUB 2 and 3.
///
/// The best structure of any format in this stage, and the reason to bother:
/// an open standard with a real table of contents, so a book is cut along its
/// chapters instead of along a character count.
public struct EPUBExtractor: DocumentTextExtractor {
    public let id = "epub"
    public let version = 1

    public init() {}

    public func canHandle(_ type: UTType) -> Bool {
        type.conforms(to: UTType("org.idpf.epub-container") ?? .data)
            || type.identifier == "org.idpf.epub-container"
            || type.preferredFilenameExtension == "epub"
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }

        let reader: ZIPContainerReader
        do {
            reader = try ZIPContainerReader(url: url)
        } catch let error as ZIPError {
            throw ExtractionError.corrupted(error.errorDescription ?? "")
        }

        // Before anything is read: a protected book is not a broken one, and
        // the app does not go around the protection.
        if reader.contains("META-INF/encryption.xml") || reader.contains("META-INF/rights.xml") {
            throw ExtractionError.drmProtected
        }

        let packagePath = try Self.packagePath(in: reader)
        let package = try Self.readPackage(at: packagePath, reader: reader)
        guard !package.spine.isEmpty else {
            throw ExtractionError.corrupted(String(localized: "в книге нет ни одной главы (пустой spine)"))
        }

        var text = ""
        var parts: [DocumentPart] = []
        var chapterHeadings: [(chapter: Int, nodes: [DocumentNode])] = []

        for (index, item) in package.spine.enumerated() {
            guard let data = try? reader.read(item.path) else { continue }
            let rendered = try await Self.renderHTML(data)
            let paragraphs = OfficeExtractor.paragraphs(of: rendered)
            guard let chapterText = PlainTextExtractor.sanitized(OfficeExtractor.render(paragraphs)) else { continue }

            if !text.isEmpty { text += "\n\n" }
            let start = text.count
            parts.append(DocumentPart(kind: .spine, index: index, id: item.id, start: start))
            text += chapterText

            // headings inside a chapter add to the structure the table of
            // contents gives. Same heuristic as — after rendering, an
            // `<h2>` is simply a larger font.
            let (nodes, source) = OfficeExtractor.structure(of: paragraphs, in: chapterText)
            if source == .heuristic {
                chapterHeadings.append((index, nodes.map {
                    DocumentNode(level: $0.level, title: $0.title, start: start + $0.start)
                }))
            }
        }

        guard let plainText = PlainTextExtractor.sanitized(text) else { throw ExtractionError.empty }

        let (structure, source) = Self.structure(
            package: package, reader: reader, parts: parts, chapterHeadings: chapterHeadings
        )
        var warnings: [ExtractionWarning] = []
        switch source {
        case .outline: break
        case .heuristic: warnings.append(.structureIsHeuristic)
        default: warnings.append(.noStructure)
        }

        return ExtractedDocument(
            plainText: plainText,
            structure: structure,
            parts: parts,
            warnings: warnings,
            structureSource: source,
            containerFormat: "epub",
            extractorID: id,
            extractorVersion: version,
            documentMetadata: options.includeDocumentMetadata ? package.metadata : [:]
        )
    }

    // MARK: - Container

    struct Package {
        var version: String
        var metadata: [String: String]
        /// Spine order — **not** the order of files in the archive.
        var spine: [SpineItem]
        /// Path of the `nav` document, when the book is EPUB 3.
        var navigationPath: String?
        /// Path of `toc.ncx`, when the book is EPUB 2.
        var ncxPath: String?
    }

    struct SpineItem {
        var id: String
        var path: String
    }

    static func packagePath(in reader: ZIPContainerReader) throws -> String {
        guard let data = try? reader.read("META-INF/container.xml") else {
            throw ExtractionError.corrupted(String(localized: "в архиве нет META-INF/container.xml"))
        }
        guard let document = try? XMLDocument(data: data),
              let node = try? document.nodes(forXPath: "//*[local-name()='rootfile']").first as? XMLElement,
              let path = node.attribute(forName: "full-path")?.stringValue,
              !path.isEmpty else {
            throw ExtractionError.corrupted(String(localized: "META-INF/container.xml не указывает на OPF"))
        }
        return (try? ZIPContainerReader.normalise(path)) ?? path
    }

    static func readPackage(at path: String, reader: ZIPContainerReader) throws -> Package {
        guard let data = try? reader.read(path), let document = try? XMLDocument(data: data) else {
            throw ExtractionError.corrupted(String(localized: "OPF не читается"))
        }
        let base = (path as NSString).deletingLastPathComponent

        var metadata: [String: String] = [:]
        for (key, element) in [("document_title", "title"), ("document_author", "creator"),
                               ("document_language", "language"), ("document_identifier", "identifier")] {
            if let value = (try? document.nodes(forXPath: "//*[local-name()='\(element)']").first)?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                metadata[key] = value
            }
        }

        // The manifest maps ids to files; the spine says in which order to read
        // them. Both are needed — one without the other is the classic bug.
        var hrefByID: [String: String] = [:]
        var propertiesByID: [String: String] = [:]
        var mediaTypeByID: [String: String] = [:]
        for case let item as XMLElement in (try? document.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue else { continue }
            hrefByID[id] = resolve(href, relativeTo: base)
            propertiesByID[id] = item.attribute(forName: "properties")?.stringValue ?? ""
            mediaTypeByID[id] = item.attribute(forName: "media-type")?.stringValue ?? ""
        }

        var spine: [SpineItem] = []
        for case let reference as XMLElement in (try? document.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? [] {
            guard let idref = reference.attribute(forName: "idref")?.stringValue,
                  let href = hrefByID[idref] else { continue }
            spine.append(SpineItem(id: idref, path: href))
        }

        let packageElement = (try? document.nodes(forXPath: "//*[local-name()='package']").first) as? XMLElement
        let spineElement = (try? document.nodes(forXPath: "//*[local-name()='spine']").first) as? XMLElement
        let navigationID = propertiesByID.first { $0.value.split(separator: " ").contains("nav") }?.key
        let ncxID = spineElement?.attribute(forName: "toc")?.stringValue
            ?? mediaTypeByID.first { $0.value == "application/x-dtbncx+xml" }?.key

        return Package(
            version: packageElement?.attribute(forName: "version")?.stringValue ?? "2.0",
            metadata: metadata,
            spine: spine,
            navigationPath: navigationID.flatMap { hrefByID[$0] },
            ncxPath: ncxID.flatMap { hrefByID[$0] }
        )
    }

    /// EPUB hrefs are relative to the document that names them, and percent
    /// encoded — `Глава%201.xhtml` has to match the entry `Глава 1.xhtml`.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let withoutFragment = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        let joined = base.isEmpty ? decoded : "\(base)/\(decoded)"
        return (try? ZIPContainerReader.normalise(joined)) ?? joined
    }

    // MARK: - Table of contents

    static func structure(
        package: Package,
        reader: ZIPContainerReader,
        parts: [DocumentPart],
        chapterHeadings: [(chapter: Int, nodes: [DocumentNode])]
    ) -> ([DocumentNode], StructureSource) {
        var entries: [TOCEntry] = []
        // EPUB 3 first, EPUB 2 second, and a book that carries both is read as
        // whichever its own package version claims.
        if package.version.hasPrefix("3"), let path = package.navigationPath,
           let data = try? reader.read(path) {
            entries = navigationEntries(data, base: (path as NSString).deletingLastPathComponent)
        }
        if entries.isEmpty, let path = package.ncxPath, let data = try? reader.read(path) {
            entries = ncxEntries(data, base: (path as NSString).deletingLastPathComponent)
        }
        if entries.isEmpty, let path = package.navigationPath, let data = try? reader.read(path) {
            entries = navigationEntries(data, base: (path as NSString).deletingLastPathComponent)
        }

        var startByPath: [String: (start: Int, index: Int)] = [:]
        for (position, part) in parts.enumerated() {
            startByPath[package.spine[part.index].path] = (part.start, position)
        }

        var nodes: [DocumentNode] = []
        var levelOfChapter: [Int: Int] = [:]
        for entry in entries {
            guard let anchor = startByPath[entry.path] else { continue }
            nodes.append(DocumentNode(level: entry.level, title: entry.title, start: anchor.start))
            // The shallowest table-of-contents level that names this chapter.
            let chapter = parts[anchor.index].index
            levelOfChapter[chapter] = min(levelOfChapter[chapter] ?? .max, entry.level)
        }

        let source: StructureSource = nodes.isEmpty ? (chapterHeadings.isEmpty ? .none : .heuristic) : .outline
        // Headings found inside a chapter sit under its table-of-contents entry.
        for (chapter, headings) in chapterHeadings {
            let base = levelOfChapter[chapter] ?? 0
            for heading in headings {
                // A chapter whose first heading repeats its own title adds
                // nothing but a duplicate.
                if nodes.contains(where: { $0.start == heading.start && $0.title == heading.title }) { continue }
                nodes.append(DocumentNode(level: base + heading.level, title: heading.title, start: heading.start))
            }
        }

        guard !nodes.isEmpty else { return ([], .none) }
        return (nodes.sorted { ($0.start, $0.level) < ($1.start, $1.level) }, source)
    }

    struct TOCEntry {
        var level: Int
        var title: String
        /// Chapter path, fragment dropped.
        var path: String
    }

    /// EPUB 3: `nav.xhtml` with `epub:type="toc"`, nested `<ol>`.
    static func navigationEntries(_ data: Data, base: String) -> [TOCEntry] {
        guard let document = try? XMLDocument(data: data, options: [.documentTidyXML]) else { return [] }
        let navigations = (try? document.nodes(forXPath: "//*[local-name()='nav']")) ?? []
        let toc = navigations.compactMap { $0 as? XMLElement }.first {
            ($0.attribute(forName: "epub:type") ?? $0.attribute(forName: "type"))?.stringValue == "toc"
        } ?? navigations.compactMap { $0 as? XMLElement }.first

        guard let toc else { return [] }
        var entries: [TOCEntry] = []
        func walk(_ list: XMLElement, level: Int) {
            for case let item as XMLElement in list.children ?? [] where item.name?.hasSuffix("li") == true {
                if let link = (try? item.nodes(forXPath: "./*[local-name()='a']").first) as? XMLElement,
                   let href = link.attribute(forName: "href")?.stringValue {
                    let title = (link.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        entries.append(TOCEntry(level: level, title: title, path: resolve(href, relativeTo: base)))
                    }
                }
                for case let nested as XMLElement in item.children ?? [] where nested.name?.hasSuffix("ol") == true {
                    walk(nested, level: level + 1)
                }
            }
        }
        for case let list as XMLElement in toc.children ?? [] where list.name?.hasSuffix("ol") == true {
            walk(list, level: 1)
        }
        return entries
    }

    /// EPUB 2: `toc.ncx`, nested `<navPoint>`.
    static func ncxEntries(_ data: Data, base: String) -> [TOCEntry] {
        guard let document = try? XMLDocument(data: data),
              let map = (try? document.nodes(forXPath: "//*[local-name()='navMap']").first) as? XMLElement else {
            return []
        }
        var entries: [TOCEntry] = []
        func walk(_ element: XMLElement, level: Int) {
            for case let point as XMLElement in element.children ?? [] where point.name?.hasSuffix("navPoint") == true {
                let title = ((try? point.nodes(forXPath: "./*[local-name()='navLabel']/*[local-name()='text']").first)?
                    .stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let source = ((try? point.nodes(forXPath: "./*[local-name()='content']").first) as? XMLElement)?
                    .attribute(forName: "src")?.stringValue
                if !title.isEmpty, let source {
                    entries.append(TOCEntry(level: level, title: title, path: resolve(source, relativeTo: base)))
                }
                walk(point, level: level + 1)
            }
        }
        walk(map, level: 1)
        return entries
    }

    // MARK: - Chapter text

    /// HTML through the same mechanism as — and on the main actor for the
    /// same reason: this importer really is the WebKit-based one.
    @MainActor
    static func renderHTML(_ data: Data) throws -> NSAttributedString {
        do {
            return try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            )
        } catch {
            throw ExtractionError.corrupted(error.localizedDescription)
        }
    }
}
