import Foundation
import AppKit

/// Чтение текстового и форматированного документа для просмотрщика.
///
/// **Читает ровно теми же правилами, что извлечение.** Кодировки — тем же
/// перебором, что `PlainTextExtractor`, форматированные документы — тем же
/// `NSAttributedString(url:options:)`, что механизм 11.4. Иначе панель
/// расходилась бы с индексом: файл, из которого чанк был извлечён, мог бы
/// не открыться — и объяснить это человеку было бы нечем.
public enum TextDocumentLoader {

    /// Выше этого файл не открывается целиком.
    ///
    /// Просмотрщик держит весь текст в памяти и рисует его в `NSTextView`;
    /// лог на сто мегабайт превратил бы «показать в документе» в зависшее
    /// окно. Предел назван человеку, а не подразумевается.
    public static let maximumBytes = 12 * 1024 * 1024

    public enum LoadError: LocalizedError, Equatable {
        case tooLarge(bytes: Int)
        case unreadableEncoding
        case parsingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                let megabytes = Double(bytes) / 1024 / 1024
                return String(localized: "Файл слишком большой для просмотра внутри приложения: \(String(format: "%.1f", megabytes)) МБ при пределе \(maximumBytes / 1024 / 1024) МБ. Откройте его во внешнем приложении.")
            case .unreadableEncoding:
                return String(localized: "Не удалось определить кодировку файла — возможно, он двоичный.")
            case .parsingFailed(let reason):
                return String(localized: "Документ не открылся: \(reason)")
            }
        }
    }

    /// Простой текст, Markdown, код, CSV, JSON.
    public static func plainText(at url: URL) throws -> String {
        try checkSize(of: url)
        // Тот же перебор кодировок, что у извлечения: UTF-8, UTF-16, latin-1.
        // Порядок важен — UTF-8 сначала, иначе кириллица прочитается как
        // мусор из latin-1 и «откроется», что хуже отказа.
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            if let text = try? String(contentsOf: url, encoding: encoding) { return text }
        }
        throw LoadError.unreadableEncoding
    }

    /// `.docx`, `.rtf`, `.odt` — тем же механизмом, что извлечение (11.4).
    @MainActor
    public static func richText(at url: URL) throws -> NSAttributedString {
        try checkSize(of: url)
        do {
            var attributes: NSDictionary?
            return try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: &attributes
            )
        } catch {
            // Тип документа не навязывается: система определит его сама по
            // содержимому, и это надёжнее, чем догадка по расширению.
            do {
                var attributes: NSDictionary?
                return try NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
            } catch {
                throw LoadError.parsingFailed(error.localizedDescription)
            }
        }
    }

    static func checkSize(of url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumBytes else { throw LoadError.tooLarge(bytes: size) }
    }
}

/// Место фрагмента в тексте: диапазон и строка, на которой он начинается.
public struct TextFragmentPlacement: Sendable, Equatable {
    /// Диапазон в символах — в том виде, в каком его принимает `NSTextView`.
    public let characterRange: Range<Int>
    /// Номер строки с единицы — то, что показывается в поле номеров и
    /// в подписи «строка N».
    public let line: Int
    public let strategy: FragmentLocator.Strategy

    public init(characterRange: Range<Int>, line: Int, strategy: FragmentLocator.Strategy) {
        self.characterRange = characterRange
        self.line = line
        self.strategy = strategy
    }

    /// Что сказать под документом. `nil` — подсветка точная, говорить нечего.
    public var note: String? {
        guard !strategy.isExact else { return nil }
        return String(localized: "\(strategy.title); подсветка приблизительная")
            .capitalizedFirst
    }
}

public extension TextFragmentPlacement {
    /// Ищет фрагмент в тексте и считает номер строки.
    static func locate(chunk: String, in text: String) -> TextFragmentPlacement? {
        guard let match = FragmentLocator.locate(chunk: chunk, in: text) else { return nil }
        let start = text.distance(from: text.startIndex, to: match.range.lowerBound)
        let end = text.distance(from: text.startIndex, to: match.range.upperBound)
        // Номер строки считается по исходному тексту до начала совпадения:
        // переводы строк в нормализованном виде схлопнуты, и считать по нему
        // значило бы назвать не ту строку.
        let line = text[text.startIndex..<match.range.lowerBound]
            .reduce(into: 1) { count, character in
                if character.isNewline { count += 1 }
            }
        return TextFragmentPlacement(
            characterRange: start..<end, line: line, strategy: match.strategy
        )
    }
}
