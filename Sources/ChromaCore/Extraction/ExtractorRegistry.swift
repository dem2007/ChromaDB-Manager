import Foundation
import UniformTypeIdentifiers

/// Picks the extractor for a file and runs the fallback chain.
///
/// Type comes from `UTType`, not from comparing extension strings: a `.pdf`
/// named `.txt` is still a PDF, and the package rule below needs the real type
/// anyway.
public struct ExtractorRegistry: Sendable {
    /// In priority order. The first that says it can handle the type wins, and
    /// the rest stay available as fallbacks.
    private let extractors: [DocumentTextExtractor]
    private let log: LogHandler

    public init(extractors: [DocumentTextExtractor], log: @escaping LogHandler = noopLogHandler) {
        self.extractors = extractors
        self.log = log
    }

    /// Everything this build can read, in the order it will be tried.
    public static func standard(log: @escaping LogHandler = noopLogHandler) -> ExtractorRegistry {
        ExtractorRegistry(
            extractors: [
                PDFExtractor(),
                EPUBExtractor(),
                OfficeExtractor(),
                IWorkExtractor(),
                // Раньше текстового: `.html` формально текст, и текстовый
                // экстрактор проиндексировал бы разметку вместе с текстом.
                HTMLExtractor(),
                PlainTextExtractor(),
                // Last on purpose: it is the fallback for a PDF with no text
                // layer, and it only runs when the source asked for it.
                VisionOCRExtractor(),
            ],
            log: log
        )
    }

    public var all: [DocumentTextExtractor] { extractors }

    public func extractor(id: String) -> DocumentTextExtractor? {
        extractors.first { $0.id == id }
    }

    /// The type of a file as the system sees it. Falls back to the extension
    /// only when the system has no opinion.
    public static func type(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension.lowercased())
    }

    /// A `.pages`, `.key` or bundled `.epub` is a directory that must be treated
    /// as **one document**. Walking into it would index `Index.zip` and
    /// `preview.jpg` as separate documents and never extract the document
    /// itself — the folder scanner asks this before descending.
    public static func isDocumentPackage(_ url: URL) -> Bool {
        guard let type = type(of: url) else { return false }
        guard type.conforms(to: .package) || type.conforms(to: .bundle) else { return false }
        // An .app is a package too, and is not a document.
        return !type.conforms(to: .application)
    }

    public func canExtract(_ url: URL) -> Bool {
        guard let type = Self.type(of: url) else { return false }
        return extractors.contains { $0.canHandle(type) }
    }

    /// Which extractor would read this file, for's version comparison.
    /// Options matter: with OCR on, a scan is the OCR extractor's file.
    public func candidate(for url: URL, options: ExtractionOptions = ExtractionOptions()) -> DocumentTextExtractor? {
        guard let type = Self.type(of: url) else { return nil }
        return extractors.first { $0.canHandle(type) && $0.isAvailable(for: options) }
    }

    /// Штамп, с которым сравнивает запись манифеста.
    ///
    /// Не «первый подходящий экстрактор», а **тот же**, что читал файл в прошлый
    /// раз, — если он и сегодня взялся бы за этот файл. У PDF, прочитанного
    /// распознаванием, первым кандидатом всегда стоит `pdfkit`: идентификаторы
    /// не совпадали, правило объявляло сравнение невозможным и молчало
    /// о таком файле навсегда, сколько бы версий ни сменил сам `vision-ocr`.
    /// Замер на рабочих манифестах: 84 файла, которым предложение переизвлечь
    /// не показалось бы никогда.
    ///
    /// Доступность важна: с выключённым распознаванием `vision-ocr` кандидатом
    /// не является, штамп возвращается чужой — и молчание снова оказывается
    /// правильным ответом, потому что переизвлекать этот скан сегодня нечем.
    ///
    /// - Parameter storedID: идентификатор экстрактора из манифеста; пустой —
    ///   запись старой сборки, для которой ответ всё равно будет «неизвестен».
    public func currentStamp(
        for type: UTType, storedID: String, options: ExtractionOptions = ExtractionOptions()
    ) -> ExtractorStamp {
        let candidates = extractors.filter { $0.canHandle(type) && $0.isAvailable(for: options) }
        guard let extractor = candidates.first(where: { $0.id == storedID }) ?? candidates.first else {
            return ExtractorStamp(id: "", version: 0)
        }
        return ExtractorStamp(id: extractor.id, version: extractor.version)
    }

    /// Runs the first matching extractor, then the next one on a failure that
    /// another extractor could plausibly recover from.
    ///
    /// Only `noTextLayer` chains: a PDF with no text layer is exactly the case
    /// OCR exists for. A password-protected or DRM-locked file is not something
    /// a different extractor can do better, and retrying it would only produce a
    /// second, less accurate error message.
    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        guard let type = Self.type(of: url) else {
            throw ExtractionError.unsupportedFormat(url.pathExtension)
        }
        let candidates = extractors.filter { $0.canHandle(type) && $0.isAvailable(for: options) }
        guard !candidates.isEmpty else {
            throw ExtractionError.unsupportedFormat(
                type.preferredFilenameExtension ?? type.identifier
            )
        }

        var lastError: Error?
        for extractor in candidates {
            do {
                return try await withTimeout(extractor.timeout(for: options)) {
                    try await extractor.extract(from: url, options: options)
                }
            } catch let error as ExtractionError {
                lastError = error
                guard case .noTextLayer = error, candidates.count > 1 else { throw error }
                log(.debug, "Извлечение", "«\(url.lastPathComponent)»: \(extractor.id) не дал текста, пробуем следующий экстрактор")
            }
        }
        throw lastError ?? ExtractionError.empty
    }

    /// One file is not allowed to hold up a folder.
    ///
    /// What this bounds is the **wait**, not the work: an extractor parked in a
    /// synchronous system call — the main-actor parse of is exactly that —
    /// cannot be interrupted from outside, and pretending otherwise would be a
    /// worse lie than a run that continues while one stray parse finishes into
    /// a result nobody reads. The file goes to «требуют решения» with the
    /// timeout as its reason, and the sync moves on.
    private func withTimeout(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> ExtractedDocument
    ) async throws -> ExtractedDocument {
        guard seconds > 0 else { return try await work() }
        return try await withThrowingTaskGroup(of: ExtractedDocument.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ExtractionError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ExtractionError.empty }
            return first
        }
    }
}

// MARK: - Plain text and code

/// Text, Markdown, CSV, JSON, source code — read as they are.
public struct PlainTextExtractor: DocumentTextExtractor {
    public let id = "plaintext"
    /// 2 — ставится `has_tables` для Markdown с таблицей. Сам текст
    /// не меняется: в Markdown таблица уже написана нужным видом.
    public let version = 2

    public init() {}

    public func canHandle(_ type: UTType) -> Bool {
        // `.text` covers plain text, source code, Markdown, CSV, JSON, XML and
        // HTML. Rich text is excluded: it is the office extractor's job, and
        // reading its markup as text would index the markup.
        guard type.conforms(to: .text) else { return false }
        return !type.conforms(to: .rtf) && !type.conforms(to: .rtfd)
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        guard let raw = Self.read(at: url) else {
            throw ExtractionError.corrupted(String(localized: "двоичный файл или неизвестная кодировка"))
        }
        guard let text = Self.sanitized(raw) else { throw ExtractionError.empty }

        return ExtractedDocument(
            plainText: text,
            containerFormat: url.pathExtension.lowercased(),
            extractorID: id,
            extractorVersion: version,
            // Таблица в Markdown уже написана тем самым видом, к которому
            // приведены остальные источники (11.13), — её надо только заметить.
            //
            // Дешёвая проверка впереди: разбирать стомегабайтный журнал
            // на строки ради одного вопроса — это его копия в памяти.
            hasTables: text.contains("---")
                && text.components(separatedBy: .newlines).contains(where: TableText.isSeparator)
        )
    }

    static func read(at url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .utf16) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        return nil
    }

    /// Trims, and refuses anything that is clearly not text whatever its
    /// extension claims.
    static func sanitized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.prefix(2000).filter({ $0.value == 0 }).count > 5 { return nil }
        return trimmed
    }
}
