import Foundation
import UniformTypeIdentifiers

/// One heading in a document's outline.
///
/// Not decoration: this is what lets Document-based chunking cut a PDF along its
/// table of contents and a Word file along its heading styles, instead of along
/// a character count that knows nothing about the text.
public struct DocumentNode: Codable, Hashable, Sendable {
    /// 1 is the top level.
    public let level: Int
    public let title: String
    /// Where this section starts in `plainText`, in characters. The section runs
    /// to the start of the next node at the same or a higher level.
    public let start: Int
    public let pageNumber: Int?

    public init(level: Int, title: String, start: Int, pageNumber: Int? = nil) {
        self.level = max(1, level)
        self.title = title
        self.start = max(0, start)
        self.pageNumber = pageNumber
    }
}

/// A piece of a document that has its own identity: an EPUB chapter, a Keynote
/// slide. Not the same thing as a page — a page is where text physically fell,
/// a part is something the document itself names.
public struct DocumentPart: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// EPUB spine item → `spine_index` and `chapter_id`.
        case spine
        /// Keynote slide → `slide_number`.
        case slide
    }

    public let kind: Kind
    /// Position in the document's own order, from 0.
    public let index: Int
    /// What the document calls it — the spine idref, the slide's name.
    public let id: String
    /// Where it starts in `plainText`, in characters.
    public let start: Int

    public init(kind: Kind, index: Int, id: String, start: Int) {
        self.kind = kind
        self.index = index
        self.id = id
        self.start = max(0, start)
    }
}

/// Адрес, на который документ ссылается, и место этой ссылки.
///
/// **Почему адрес — метаданное, а не текст чанка.** Замер на 400 PDF: 471
/// разный адрес, и почти все — непрозрачные редиректы вида
/// `internet.garant.ru/document/redirect/71886920/0`. В них нет ни одного
/// слова, по которому их станут искать, а в векторе они дают набор цифр.
/// В метаданных адрес доступен человеку, агенту и фильтру — и вектор
/// не размывает.
public struct DocumentLink: Codable, Hashable, Sendable {
    public let url: String
    /// Где в `plainText` стоит ссылка, в знаках.
    public let start: Int

    public init(url: String, start: Int) {
        self.url = url
        self.start = max(0, start)
    }
}

/// Where the structure came from — the user is entitled to know how much to
/// trust it.
public enum StructureSource: String, Codable, Sendable {
    case none
    /// A real table of contents: PDF outline, EPUB nav/ncx.
    case outline
    /// Paragraph styles, as in a `.docx`.
    case headings
    /// Guessed from font size or weight.
    case heuristic
    /// iWork fallbacks, where quality is admittedly lower.
    case previewPDF = "preview-pdf"
    case legacyXML = "legacy-xml"
}

/// Something the user should know about this extraction. Reaches the chunk
/// metadata as a flat string — ChromaDB metadata has no arrays.
public enum ExtractionWarning: Hashable, Sendable {
    case structureIsHeuristic
    case noStructure
    case tablesFlattened
    /// Таблица на странице была, но собрать её не удалось.
    ///
    /// Не то же, что `tablesFlattened`: там строки и колонки на месте,
    /// теряется оформление. Здесь теряются сами колонки — текст уходит
    /// сеткой чисел, где не отличить цену от итога.
    case tablesNotAssembled(pages: Int)
    case commentsSkipped
    case ocrUsed(averageConfidence: Double)
    case speakerNotesUnavailable
    case other(String)

    public var text: String {
        switch self {
        case .structureIsHeuristic:
            return String(localized: "структура определена эвристикой, а не оглавлением")
        case .noStructure:
            return String(localized: "структура не найдена — текст плоский")
        case .tablesFlattened:
            // Не «разметка потеряна»: строки и колонки как раз
            // сохраняются — разметкой Markdown. Теряется оформление: ширины,
            // объединения, цвета. Говорить про приложение то, чего оно
            // не делает, нельзя даже в оговорке.
            return String(localized: "таблицы записаны текстом: строки и колонки сохранены, оформление — нет")
        case .tablesNotAssembled(let pages):
            return String(localized: "на \(pages.plainDigits) страницах таблица осталась плоским текстом: колонки в ней не разделены, и на числа оттуда опираться нельзя")
        case .commentsSkipped:
            // Для `.docx` эта оговорка больше не ставится: там сноски
            // и комментарии извлекаются, а правки принимаются, и говорить
            // «не извлекаются» значило бы врать о самом приложении.
            // Остаётся у `.odt` и там, где часть с комментариями не читается.
            return String(localized: "комментарии, сноски и правки не извлечены")
        case .ocrUsed(let confidence):
            return String(localized: "текст распознан OCR (средняя уверенность \(String(format: "%.2f", confidence))) — ошибки распознавания возможны")
        case .speakerNotesUnavailable:
            return String(localized: "заметки докладчика недоступны на этом пути извлечения")
        case .other(let text):
            return text
        }
    }
}

/// The result of reading one document.
public struct ExtractedDocument: Sendable {
    public var plainText: String
    public var structure: [DocumentNode]
    public var pageCount: Int?
    /// Where each page starts in `plainText`, so a chunk can say which page it
    /// came from. Empty for formats without pages.
    public var pageStarts: [Int]
    /// Chapters or slides, in the document's own order.
    public var parts: [DocumentPart]
    /// Адреса, на которые ссылается документ, с их местом в тексте.
    public var links: [DocumentLink]
    /// Where the paged text ends, in characters. Text past this offset was added
    /// by the extractor from somewhere other than the pages — Keynote's
    /// presenter notes are the case this exists for — and is on no page at all.
    /// `nil` means every character came off a page, which is the ordinary case.
    ///
    /// Without it the last page swallows everything appended after it, and a
    /// note for slide 1 reports the page number of the final slide.
    public var pagedTextEnd: Int?
    public var warnings: [ExtractionWarning]
    public var structureSource: StructureSource
    /// `pdf`, `docx`, `epub`, … — goes into the chunk metadata as
    /// `container_format`.
    public var containerFormat: String
    public var extractorID: String
    public var extractorVersion: Int
    /// `nil` means «this extractor does not look for tables», which is not the
    /// same as «there are none» — `has_tables: false` from an extractor that
    /// never checked would be a claim rather than a fact.
    public var hasTables: Bool?
    /// `true` when the text was recognised rather than read. `nil` from
    /// an extractor for which the question does not arise.
    public var ocrUsed: Bool?
    /// Average recognition confidence, 0…1, weighted by how much text each
    /// observation carried.
    public var ocrConfidence: Double?
    /// Extra per-document metadata an extractor chose to expose (title, author,
    /// spine index …). Written to chunks only when the source asks for it.
    public var documentMetadata: [String: String]

    public init(
        plainText: String,
        structure: [DocumentNode] = [],
        pageCount: Int? = nil,
        pageStarts: [Int] = [],
        parts: [DocumentPart] = [],
        links: [DocumentLink] = [],
        pagedTextEnd: Int? = nil,
        warnings: [ExtractionWarning] = [],
        structureSource: StructureSource = .none,
        containerFormat: String,
        extractorID: String,
        extractorVersion: Int,
        hasTables: Bool? = nil,
        ocrUsed: Bool? = nil,
        ocrConfidence: Double? = nil,
        documentMetadata: [String: String] = [:]
    ) {
        self.plainText = plainText
        self.structure = structure
        self.pageCount = pageCount
        self.pageStarts = pageStarts
        self.parts = parts
        self.links = links
        self.pagedTextEnd = pagedTextEnd
        self.warnings = warnings
        self.structureSource = structureSource
        self.containerFormat = containerFormat
        self.extractorID = extractorID
        self.extractorVersion = extractorVersion
        self.hasTables = hasTables
        self.ocrUsed = ocrUsed
        self.ocrConfidence = ocrConfidence
        self.documentMetadata = documentMetadata
    }

    /// The page a character offset falls on, 1-based. `nil` where the format has
    /// no pages.
    public func pageNumber(forCharacter offset: Int) -> Int? {
        guard !pageStarts.isEmpty else { return nil }
        if let end = pagedTextEnd, offset >= end { return nil }
        var page = 1
        for (index, start) in pageStarts.enumerated() where start <= offset {
            page = index + 1
        }
        return page
    }

    /// The chapter or slide a character offset falls in.
    public func part(forCharacter offset: Int) -> DocumentPart? {
        var result: DocumentPart?
        for part in parts where part.start <= offset {
            result = part
        }
        return result
    }

    /// `Глава 2 > Раздел 2.1` for a character offset — the `heading_path` of
    /// 9, built here so every extractor spells it the same way.
    public func headingPath(forCharacter offset: Int, separator: String = " > ") -> String? {
        let preceding = structure.filter { $0.start <= offset }
        guard !preceding.isEmpty else { return nil }

        // Walk backwards keeping only headings that still contain this offset:
        // a level-2 heading is inside the last level-1 heading before it.
        var path: [DocumentNode] = []
        for node in preceding.reversed() {
            if let deepest = path.last, node.level >= deepest.level { continue }
            path.append(node)
            if node.level == 1 { break }
        }
        return path.reversed().map(\.title).joined(separator: separator)
    }
}

/// How far an extraction has got. Reported for the slow paths only — reading a
/// text layer is over before a progress bar could draw.
public struct ExtractionProgress: Sendable, Hashable {
    public enum Stage: String, Sendable {
        case recognising
        case exporting
    }

    public let stage: Stage
    /// 1-based: page 3 of 40.
    public let unit: Int
    public let total: Int

    public init(stage: Stage, unit: Int, total: Int) {
        self.stage = stage
        self.unit = unit
        self.total = total
    }

    public var text: String {
        switch stage {
        case .recognising: return String(localized: "распознавание: страница \(unit) из \(total)")
        case .exporting: return String(localized: "экспорт: \(unit) из \(total)")
        }
    }
}

/// What the source asks of an extraction.
public struct ExtractionOptions: Sendable {
    public var maxFileSize: Int64
    /// OCR is off unless the source asks: it is an order of magnitude slower and
    /// the user has to learn that before pointing it at a thousand files.
    public var ocrEnabled: Bool
    public var ocrLanguages: [String]
    /// Document title, author, dates into the chunk metadata.
    public var includeDocumentMetadata: Bool
    public var perFileTimeout: TimeInterval
    /// Separate and much larger than `perFileTimeout`: recognising one page can
    /// legitimately take seconds, and asks for its own limit.
    public var ocrPageTimeout: TimeInterval
    /// Called from the slow extractors so a run can say where it is.
    public var progress: (@Sendable (ExtractionProgress) -> Void)?
    /// Opening a GUI app to export a document is not something to do behind the
    /// user's back during an automatic run.
    public var allowApplicationExport: Bool
    /// Its own limit, and a generous one: the export raises Pages or Keynote,
    /// which can put up a dialog and wait for a person who is not there.
    public var exportTimeout: TimeInterval
    /// The password for this one file, when the user has given one.
    ///
    /// Never carried in the source's settings and never written to `config.json`:
    /// it comes out of the Keychain for the duration of one extraction (rule 7
    /// of Приложение 5).
    public var password: String?

    public init(
        maxFileSize: Int64 = ExtractionOptions.defaultMaxFileSize,
        ocrEnabled: Bool = false,
        ocrLanguages: [String] = [],
        includeDocumentMetadata: Bool = false,
        perFileTimeout: TimeInterval = 60,
        ocrPageTimeout: TimeInterval = 120,
        allowApplicationExport: Bool = false,
        exportTimeout: TimeInterval = 120,
        password: String? = nil,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) {
        self.maxFileSize = maxFileSize
        self.ocrEnabled = ocrEnabled
        self.ocrLanguages = ocrLanguages
        self.includeDocumentMetadata = includeDocumentMetadata
        self.perFileTimeout = perFileTimeout
        self.ocrPageTimeout = ocrPageTimeout
        self.allowApplicationExport = allowApplicationExport
        self.exportTimeout = exportTimeout
        self.password = password
        self.progress = progress
    }

    public static let defaultMaxFileSize: Int64 = 50 * 1024 * 1024
}

/// Why a file did not produce text. Every case is a reason the user can act on —
/// «требуют решения» with a cause, never a silent skip or a bare zero chunks
///.
public enum ExtractionError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case tooLarge(size: Int64, limit: Int64)
    case corrupted(String)
    case passwordProtected
    /// A password was given and the file did not accept it. Kept apart from
    /// `passwordProtected` so the diagnostics screen can say «the password is
    /// wrong» instead of asking for one the user has already typed.
    case wrongPassword
    case drmProtected
    /// A PDF whose pages carry no text layer. `looksLikeScan` separates «a
    /// picture of text, turn on OCR» from «genuinely empty».
    case noTextLayer(looksLikeScan: Bool)
    case empty
    case timedOut(seconds: TimeInterval)
    case applicationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let detail):
            return String(localized: "формат не поддерживается: \(detail)")
        case .tooLarge(let size, let limit):
            return String(localized: "файл больше предела (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) при пределе \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)))")
        case .corrupted(let detail):
            return String(localized: "файл не читается: \(detail)")
        case .passwordProtected:
            return String(localized: "файл защищён паролем")
        case .wrongPassword:
            return String(localized: "сохранённый пароль не подошёл")
        case .drmProtected:
            return String(localized: "файл защищён DRM")
        case .noTextLayer(let looksLikeScan):
            return looksLikeScan
                ? String(localized: "нет текстового слоя — похоже на скан; включите распознавание в настройках источника")
                : String(localized: "текст не извлечён — в документе его нет")
        case .empty:
            return String(localized: "файл пустой")
        case .timedOut(let seconds):
            return String(localized: "извлечение не уложилось в \(Int(seconds).plainDigits) с")
        case .applicationUnavailable(let detail):
            return detail
        }
    }
}

/// One way of turning a file into text.
///
/// A protocol and a registry rather than a `switch` on file extension: every
/// format after the first two brings its own fallbacks, warnings and structure,
/// and a switch would have become the place where all of that got tangled.
public protocol DocumentTextExtractor: Sendable {
    /// Stable across versions — it is written into the manifest and into chunk
    /// metadata, and changing it means every file looks newly extracted.
    var id: String { get }
    /// Bumped when the extraction logic changes. turns that into an offer
    /// to re-extract, never into an automatic recount.
    var version: Int { get }
    func canHandle(_ type: UTType) -> Bool
    /// Whether this extractor may run at all under these options. OCR is the
    /// case it exists for: it handles PDFs, but only when the source asked for
    /// recognition.
    func isAvailable(for options: ExtractionOptions) -> Bool
    /// How long this extractor may take on one file. `0` means the registry
    /// imposes no limit of its own — for an extractor that bounds its own work
    /// more precisely than a single number can.
    func timeout(for options: ExtractionOptions) -> TimeInterval
    func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument
}

public extension DocumentTextExtractor {
    func isAvailable(for options: ExtractionOptions) -> Bool { true }
    func timeout(for options: ExtractionOptions) -> TimeInterval { options.perFileTimeout }
}
