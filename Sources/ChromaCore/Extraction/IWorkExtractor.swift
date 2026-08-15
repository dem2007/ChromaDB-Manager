import Foundation
import UniformTypeIdentifiers

/// Pages and Keynote.
///
/// **What this deliberately does not do** is parse `Index/*.iwa`. Those are
/// protobuf streams with Snappy compression and undocumented schemas that change
/// between iWork releases; reverse-engineering them buys a reader that breaks on
/// the next update. The spec forbids it, and it is right to.
///
/// The order of attempts is fixed: ask the application to export → the
/// `QuickLook/Preview.pdf` that iWork '09 files carry → the `index.xml` of the
/// same era → «needs a decision» with a reason. Anything the app did not export
/// is marked as the lower-quality path it is.
public struct IWorkExtractor: DocumentTextExtractor {
    public let id = "iwork"
    public let version = 1

    private let exporter: IWorkExporting

    public init(exporter: IWorkExporting = AppleScriptIWorkExporter()) {
        self.exporter = exporter
    }

    public func canHandle(_ type: UTType) -> Bool { Self.kind(of: type) != nil }

    /// The export gets its own limit, and the ordinary per-file one must not
    /// undercut it. Found live: the first export waits for the automation
    /// prompt, took 63 s, and the registry's 60 s killed it — reporting a
    /// timeout for a document Keynote was in the middle of exporting.
    public func timeout(for options: ExtractionOptions) -> TimeInterval {
        max(options.perFileTimeout, options.exportTimeout)
    }

    public enum Kind: String, Sendable {
        case pages
        case keynote

        public var applicationName: String { self == .pages ? "Pages" : "Keynote" }
        /// Addressed by identifier, never by name — and by **Apple's** one.
        ///
        /// Found live, and worth spelling out. `tell application "Keynote"` on
        /// the test machine reached a third-party «Keynote Creator Studio»,
        /// which swallowed the document and timed the AppleEvent out (-1712).
        /// That app declares `CFBundleIdentifier = com.apple.Keynote`, so the
        /// obvious identifier is no safer than the name. Apple's own iWork apps
        /// have used `com.apple.iWork.*` for years, and that is what is asked
        /// for here.
        var bundleIdentifier: String { self == .pages ? "com.apple.iWork.Pages" : "com.apple.iWork.Keynote" }
        var containerFormat: String { self == .pages ? "pages" : "key" }
    }

    static func kind(of type: UTType) -> Kind? {
        for identifier in ["com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages"]
        where type.conforms(to: UTType(identifier) ?? .data) {
            return .pages
        }
        for identifier in ["com.apple.iwork.keynote.key", "com.apple.iwork.keynote.sffkey"]
        where type.conforms(to: UTType(identifier) ?? .data) {
            return .keynote
        }
        return nil
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        guard let type = ExtractorRegistry.type(of: url), let kind = Self.kind(of: type) else {
            throw ExtractionError.unsupportedFormat(url.pathExtension)
        }

        var reasons: [String] = []

        // 1. The official way: the application's own object model.
        if options.allowApplicationExport {
            do {
                return try await exportPath(url, kind: kind, options: options)
            } catch let error as ExtractionError {
                reasons.append(error.errorDescription ?? "")
            }
        } else {
            reasons.append(String(localized: "экспорт через приложение выключен в настройках источника"))
        }

        // 2. iWork '09 kept a real PDF inside. Modern files do not — only
        //    `preview.jpg`, and usually of the first page alone, which is why
        //    that is never used: one page of text pretending to be a document
        //    is worse than an honest refusal.
        if let container = try? IWorkContainer(url: url) {
            if let data = container.read("QuickLook/Preview.pdf") {
                do {
                    return try await previewPDFPath(data, kind: kind, options: options)
                } catch let error as ExtractionError {
                    reasons.append(error.errorDescription ?? "")
                }
            }
            // 3. …and an XML body, which is cheap to read and worth reading.
            if let data = container.read("index.xml") ?? container.read("Index.xml") {
                if let document = legacyXMLPath(data, kind: kind) { return document }
                reasons.append(String(localized: "index.xml не разобран"))
            }
        }

        throw ExtractionError.applicationUnavailable(
            String(localized: "\(kind.applicationName): документ не удалось прочитать — \(reasons.joined(separator: "; "))")
        )
    }

    // MARK: - 1. Export through the application

    private func exportPath(_ url: URL, kind: Kind, options: ExtractionOptions) async throws -> ExtractedDocument {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-iwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Removed on every path out of here, including the failures: temporary
        // copies of the user's documents must not outlive the extraction.
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdf = directory.appendingPathComponent("export.pdf")
        try await exporter.exportPDF(from: url, to: pdf, kind: kind, timeout: options.exportTimeout)
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            throw ExtractionError.applicationUnavailable(
                String(localized: "\(kind.applicationName) не создал PDF")
            )
        }

        var document = try await PDFExtractor().extract(from: pdf, options: options)
        document.containerFormat = kind.containerFormat
        document.extractorID = id
        document.extractorVersion = version
        document.structureSource = document.structure.isEmpty ? .none : document.structureSource

        if kind == .keynote {
            document = slides(in: document)
            // Presenter notes live in the object model, not in the exported PDF,
            // and are often more substantial than the slides themselves.
            if let notes = try? await exporter.presenterNotes(from: url, timeout: options.exportTimeout),
               !notes.isEmpty {
                document = appending(notes: notes, to: document)
            } else {
                document.warnings.append(.speakerNotesUnavailable)
            }
        }
        return document
    }

    /// One PDF page is one slide.
    private func slides(in document: ExtractedDocument) -> ExtractedDocument {
        var result = document
        result.parts = document.pageStarts.enumerated().map { index, start in
            DocumentPart(kind: .slide, index: index, id: "slide-\(index + 1)", start: start)
        }
        // The first line of a slide is its title, and that is what a search
        // result should be able to say it came from.
        result.structure = result.parts.compactMap { part in
            guard let title = Self.firstLine(of: document.plainText, from: part.start), !title.isEmpty else { return nil }
            return DocumentNode(level: 1, title: title, start: part.start, pageNumber: part.index + 1)
        }
        result.structureSource = result.structure.isEmpty ? .none : .outline
        // The PDF had no outline of its own, so PDFExtractor said so. The slides
        // are that outline, and a warning that contradicts the structure beside
        // it teaches the user to ignore warnings.
        if !result.structure.isEmpty {
            result.warnings.removeAll { $0 == .noStructure }
        }
        return result
    }

    /// Presenter notes, each one belonging to the slide it was written for.
    ///
    /// Appended after the slides rather than woven between them: the offsets of
    /// every slide are already fixed, and moving them to interleave notes would
    /// put every chunk on the wrong slide. But «after the last slide» is not the
    /// same as «on the last slide» — found live, where the notes for slides 1
    /// and 2 arrived in the chunk for slide 3, carrying its number and its
    /// title. Each block therefore becomes a part of its own, pointing back at
    /// the slide it came from, and the paged text ends where the slides do.
    private func appending(notes: [Int: String], to document: ExtractedDocument) -> ExtractedDocument {
        var result = document
        var text = document.plainText
        result.pagedTextEnd = text.count

        let ordered = notes.sorted { $0.key < $1.key }
        for (index, note) in ordered where !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let heading = String(localized: "Заметки к слайду \(index + 1)")
            text += "\n\n"
            let start = text.count
            text += heading + "\n" + note
            result.parts.append(
                DocumentPart(kind: .slide, index: index, id: "slide-\(index + 1)-notes", start: start)
            )
            // No page number: these words are in the presentation, not in the
            // PDF Keynote exported.
            result.structure.append(DocumentNode(level: 1, title: heading, start: start))
        }
        result.plainText = text
        return result
    }

    static func firstLine(of text: String, from offset: Int) -> String? {
        guard offset >= 0, offset < text.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: offset)
        let rest = text[start...]
        let line = rest.prefix { $0 != "\n" }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 2. The preview PDF of an iWork '09 file

    private func previewPDFPath(_ data: Data, kind: Kind, options: ExtractionOptions) async throws -> ExtractedDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdbm-iwork-preview-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var document = try await PDFExtractor().extract(from: url, options: options)
        document.containerFormat = kind.containerFormat
        document.extractorID = id
        document.extractorVersion = version
        // Said plainly, because the quality really is lower: this is whatever
        // iWork happened to render, not what the application would export.
        document.structureSource = .previewPDF
        document.warnings.append(.other(String(localized: "текст взят из PDF-превью внутри файла — качество ниже, чем при экспорте через \(kind.applicationName)")))
        if kind == .keynote { document.warnings.append(.speakerNotesUnavailable) }
        return document
    }

    // MARK: - 3. iWork '09 XML

    private func legacyXMLPath(_ data: Data, kind: Kind) -> ExtractedDocument? {
        guard let document = try? XMLDocument(data: data, options: [.documentTidyXML]) else { return nil }
        let nodes = (try? document.nodes(forXPath: "//*[local-name()='p']")) ?? []
        let paragraphs = nodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let text = PlainTextExtractor.sanitized(paragraphs.joined(separator: "\n\n")) else { return nil }

        var warnings: [ExtractionWarning] = [
            .other(String(localized: "файл в старом формате iWork '09 — текст взят из index.xml, оформление и структура потеряны")),
        ]
        if kind == .keynote { warnings.append(.speakerNotesUnavailable) }
        return ExtractedDocument(
            plainText: text,
            warnings: warnings,
            structureSource: .legacyXML,
            containerFormat: kind.containerFormat,
            extractorID: id,
            extractorVersion: version,
            // Про таблицы в старом XML-формате Pages сказать нечего: разметка
            // ячеек в нём не размечена как таблица, и выдавать «их нет»
            // за проверку нельзя. `nil` — это «не проверяли», и так честнее.
            hasTables: nil
        )
    }
}

// MARK: - Container

/// A `.pages`/`.key` is either a single ZIP file **or** a package directory
///. Both are read here, so the rest of the extractor need not care.
struct IWorkContainer {
    private let zip: ZIPContainerReader?
    private let directory: URL?

    init(url: URL) throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            directory = url
            zip = nil
        } else {
            directory = nil
            zip = try ZIPContainerReader(url: url)
        }
    }

    func read(_ path: String) -> Data? {
        if let directory {
            return try? Data(contentsOf: directory.appendingPathComponent(path))
        }
        return try? zip?.read(path)
    }
}

// MARK: - Export

/// Asking the application to export is the one part that has to be faked in
/// tests: it opens a GUI application and needs a permission the test target
/// cannot grant.
public protocol IWorkExporting: Sendable {
    func exportPDF(from url: URL, to destination: URL, kind: IWorkExtractor.Kind, timeout: TimeInterval) async throws
    func presenterNotes(from url: URL, timeout: TimeInterval) async throws -> [Int: String]
}

/// The real thing: `osascript` against Pages' and Keynote's own object model.
///
/// Strictly one file at a time — every call raises a GUI application, and two of
/// them at once is a fight over the same window server.
public struct AppleScriptIWorkExporter: IWorkExporting {
    public init() {}

    public func exportPDF(from url: URL, to destination: URL, kind: IWorkExtractor.Kind, timeout: TimeInterval) async throws {
        let script = """
        set input to POSIX file "\(Self.escaped(url.path))"
        set output to POSIX file "\(Self.escaped(destination.path))"
        tell application id "\(kind.bundleIdentifier)"
            set doc to open input
            export doc to output as PDF
            close doc saving no
        end tell
        """
        try await Self.run(script, timeout: timeout, application: kind.applicationName)
    }

    public func presenterNotes(from url: URL, timeout: TimeInterval) async throws -> [Int: String] {
        let script = """
        set input to POSIX file "\(Self.escaped(url.path))"
        set out to ""
        tell application id "com.apple.iWork.Keynote"
            set doc to open input
            repeat with i from 1 to count of slides of doc
                set out to out & "<<<CDBM-SLIDE " & i & ">>>" & (presenter notes of slide i of doc) & linefeed
            end repeat
            close doc saving no
        end tell
        return out
        """
        let output = try await Self.run(script, timeout: timeout, application: "Keynote")
        return Self.parseNotes(output)
    }

    static func parseNotes(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for piece in output.components(separatedBy: "<<<CDBM-SLIDE ") {
            guard let close = piece.range(of: ">>>"),
                  let number = Int(piece[piece.startIndex..<close.lowerBound].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            let note = String(piece[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { result[number - 1] = note }
        }
        return result
    }

    /// Quotes are the only character AppleScript string literals cannot hold
    /// unescaped, and a path is user data.
    static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    static func run(_ script: String, timeout: TimeInterval, application: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw ExtractionError.applicationUnavailable(
                String(localized: "не удалось запустить osascript: \(error.localizedDescription)")
            )
        }

        // A hard limit, because a GUI application can put up a dialog and wait
        // for a person who is not there.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw ExtractionError.timedOut(seconds: timeout)
            }
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExtractionError.applicationUnavailable(Self.explain(message, application: application))
        }
        return text
    }

    /// Turns the system's numbered refusals into something a person can act on.
    static func explain(_ message: String, application: String) -> String {
        if message.contains("-1743") || message.lowercased().contains("not allowed") {
            return String(localized: "нет разрешения на автоматизацию \(application). Системные настройки → Конфиденциальность и безопасность → Автоматизация → разрешите ChromaDB Manager управлять \(application)")
        }
        if message.contains("-1728") || message.contains("-10814") || message.contains("-600") {
            return String(localized: "\(application) не установлен или не отвечает")
        }
        if message.contains("-1712") {
            return String(localized: "\(application) не ответил вовремя — документ мог остаться открытым в программе")
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "\(application) не смог экспортировать документ")
            : String(localized: "\(application): \(trimmed)")
    }
}
