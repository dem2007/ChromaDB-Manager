import Foundation
import UniformTypeIdentifiers

/// Куда именно внутри документа вести.
///
/// Один случай на формат, а не общее «место»: страница PDF, глава EPUB
/// и строка листа — разные вещи, и просмотрщик каждого формата умеет ровно
/// свою. Метаданные для всех этих случаев пишутся синхронизацией.
public enum ViewerTarget: Sendable, Equatable {
    case page(Int)
    case chapter(id: String?, spineIndex: Int?)
    case slide(Int)
    case tableRow(sheet: String?, row: Int?)
    /// Место известно только по заголовкам — для форматов без страниц.
    case heading(String)
    /// Ничего не известно: открыть с начала. Это не ошибка (шаг 4).
    case wholeDocument

    public var line: String? {
        switch self {
        case .page(let number): return String(localized: "страница \(number)")
        case .chapter(let id, let index):
            if let id, !id.isEmpty { return String(localized: "глава «\(id)»") }
            return index.map { String(localized: "глава \($0 + 1)") }
        case .slide(let number): return String(localized: "слайд \(number)")
        case .tableRow(let sheet, let row):
            var parts: [String] = []
            if let sheet, !sheet.isEmpty { parts.append(String(localized: "лист «\(sheet)»")) }
            if let row { parts.append(String(localized: "строка \(row)")) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .heading(let path): return path.isEmpty ? nil : path
        case .wholeDocument: return nil
        }
    }
}

/// Чем показывать документ.
public enum ViewerKind: String, Sendable, Equatable {
    case pdf
    /// Текст, Markdown, код, CSV, JSON — моноширинный шрифт и номера строк.
    case plainText
    /// `.docx`, `.rtf`, `.odt` — через уже написанный механизм 11.4.
    case richText
    case epub
    /// Таблица: переход к строке листа.
    case table
    /// Показать внутри нельзя — только отдать системе. Keynote и Pages без
    /// сохранённого экспорта, а также всё незнакомое.
    case externalOnly

    public var title: String {
        switch self {
        case .pdf: return "PDF"
        case .plainText: return String(localized: "текст")
        case .richText: return String(localized: "документ")
        case .epub: return "EPUB"
        case .table: return String(localized: "таблица")
        case .externalOnly: return String(localized: "внешнее приложение")
        }
    }
}

/// Что известно про исходник результата поиска.
public struct SourceReference: Sendable, Equatable {
    /// Источник данных, из которого пришёл документ.
    public let sourceID: UUID?
    public let sourceName: String?
    /// Путь относительно папки источника — то, что синхронизация пишет
    /// в `source_file` (несмотря на имя ключа).
    public let relativePath: String?
    public let fileName: String?
    public let target: ViewerTarget

    public init(
        sourceID: UUID?, sourceName: String?, relativePath: String?,
        fileName: String?, target: ViewerTarget
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.relativePath = relativePath
        self.fileName = fileName
        self.target = target
    }

    /// Путь, каким он был при индексации, — для сообщений об исчезнувшем файле.
    public var savedPath: String {
        relativePath ?? fileName ?? String(localized: "путь неизвестен")
    }
}

/// Чем закончилась попытка найти исходник.
public enum DocumentResolution: Sendable, Equatable {
    case found(url: URL, kind: ViewerKind, target: ViewerTarget)
    /// Источник зарегистрирован, но файла по этому пути нет.
    case fileMissing(expected: URL, reference: SourceReference)
    /// Источник, из которого пришёл документ, больше не зарегистрирован —
    /// значит папку никто не знает, и угадывать её нельзя.
    case sourceUnknown(reference: SourceReference)
    /// Документ добавлен руками, а не из файла: показывать нечего, и это
    /// не поломка.
    case notFromFile

    public var url: URL? {
        if case .found(let url, _, _) = self { return url }
        return nil
    }

    /// Что сказать человеку, когда показать нечего. `nil` — показывать есть что.
    public var problem: String? {
        switch self {
        case .found:
            return nil
        case .fileMissing(let expected, let reference):
            return String(localized: "Файл не найден: \(expected.path). При индексации он лежал по пути «\(reference.savedPath)» в источнике «\(reference.sourceName ?? "—")». Укажите новое расположение источника на экране «Эмбеддинги».")
        case .sourceUnknown(let reference):
            return String(localized: "Источник «\(reference.sourceName ?? "—")» больше не зарегистрирован — папку, в которой лежал файл «\(reference.savedPath)», приложение не знает. Добавьте источник заново, и просмотр заработает.")
        case .notFromFile:
            return String(localized: "Документ добавлен вручную, а не из файла — исходника у него нет.")
        }
    }
}

/// Разрешение «результат поиска → файл на диске и место в нём».
public enum DocumentLocator {

    /// Читает из метаданных чанка всё, что относится к исходнику.
    public static func reference(metadata: ChromaMetadata?) -> SourceReference {
        let relativePath = string(metadata, "source_file")
        return SourceReference(
            sourceID: string(metadata, "source_id").flatMap(UUID.init(uuidString:)),
            sourceName: string(metadata, "_cdbm_source_name"),
            relativePath: relativePath,
            // `file_name` пишут не все стратегии — у строк таблицы его нет.
            // Имя файла при этом известно: оно в конце относительного пути.
            fileName: string(metadata, "file_name")
                ?? relativePath.map { ($0 as NSString).lastPathComponent },
            target: target(metadata: metadata)
        )
    }

    /// Куда вести внутри документа.
    ///
    /// Порядок разбора — от точного к приблизительному: страница точнее
    /// главы, глава точнее пути заголовков. Заголовки идут последними
    /// потому, что это единственное, что есть у форматов без страниц.
    public static func target(metadata: ChromaMetadata?) -> ViewerTarget {
        if let page = int(metadata, "page_number") { return .page(page) }
        if let slide = int(metadata, "slide_number") { return .slide(slide) }
        let chapter = string(metadata, "chapter_id")
        let spine = int(metadata, "spine_index")
        if chapter != nil || spine != nil {
            return .chapter(id: chapter, spineIndex: spine)
        }
        let sheet = string(metadata, "sheet_name")
        let row = int(metadata, "row_number")
        if sheet != nil || row != nil {
            return .tableRow(sheet: sheet, row: row)
        }
        if let heading = string(metadata, "heading_path"), !heading.isEmpty {
            return .heading(heading)
        }
        return .wholeDocument
    }

    /// Ищет файл. `fileExists` вынесен параметром, чтобы правило проверялось
    /// тестом, а не только на живой файловой системе.
    public static func resolve(
        metadata: ChromaMetadata?,
        sources: [DataSource],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> DocumentResolution {
        let reference = self.reference(metadata: metadata)

        // Документ, добавленный руками, отличается от пришедшего из файла
        // не отсутствием пути, а происхождением — и сказать об этом надо
        // именно так, а не «файл не найден».
        guard reference.sourceID != nil || reference.relativePath != nil else {
            return .notFromFile
        }
        guard let relativePath = reference.relativePath, !relativePath.isEmpty else {
            return .sourceUnknown(reference: reference)
        }

        // Источник ищется по идентификатору, а не по имени: имя человек
        // переименовывает, идентификатор — нет.
        let source = reference.sourceID.flatMap { id in sources.first { $0.id == id } }
            ?? reference.sourceName.flatMap { name in sources.first { $0.name == name } }
        guard let source else {
            return .sourceUnknown(reference: reference)
        }

        let url = URL(fileURLWithPath: source.path)
            .appendingPathComponent(relativePath)
        guard fileExists(url) else {
            return .fileMissing(expected: url, reference: reference)
        }
        return .found(url: url, kind: kind(of: url), target: reference.target)
    }

    /// Чем открывать — по `UTType`, а не по расширению.
    ///
    /// Тем же способом, что выбирает извлечение (`canHandle(_ type:)`):
    /// `.docx`, переименованный в `.doc`, остаётся `.docx`, и просмотрщик
    /// обязан согласиться с тем, что решил экстрактор. Разбор по строке
    /// расширения разошёлся бы с ним на первом же таком файле.
    public static func kind(of url: URL) -> ViewerKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return .externalOnly
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.identifier == "org.idpf.epub-container"
            || url.pathExtension.lowercased() == "epub" { return .epub }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return .richText }
        if type.conforms(to: UTType("org.openxmlformats.wordprocessingml.document") ?? .data)
            || type.conforms(to: UTType("org.oasis-open.opendocument.text") ?? .data) {
            return .richText
        }
        if type.conforms(to: .spreadsheet)
            || type.conforms(to: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data) {
            return .table
        }
        // `.text` покрывает простой текст, код, Markdown, CSV, JSON, XML
        // и HTML — ровно то же, что берёт себе экстрактор простого текста.
        if type.conforms(to: .text) { return .plainText }
        return .externalOnly
    }

    // MARK: - Чтение метаданных

    static func string(_ metadata: ChromaMetadata?, _ key: String) -> String? {
        guard case .string(let value)? = metadata?[key], !value.isEmpty else { return nil }
        return value
    }

    static func int(_ metadata: ChromaMetadata?, _ key: String) -> Int? {
        switch metadata?[key] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        // Число, приехавшее строкой, — обычное дело для чужой коллекции,
        // и терять из-за этого переход на страницу незачем.
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}
