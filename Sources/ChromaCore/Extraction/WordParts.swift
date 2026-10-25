import Foundation

/// Модель разобранного вордовского документа — общая для обоих форматов.
///
/// Заведена, когда к `.docx` добавился двоичный `.doc`: читалки у них
/// разные до последнего байта, а результат обязан быть один — иначе сборка
/// текста, нарезка и оговорки раздвоятся, и два формата начнут расходиться
/// в мелочах, которых никто не заметит.
public enum WordParts {
    /// Один абзац документа, каким его написали.
    public struct Paragraph: Hashable, Sendable {
        public var text: String
        /// Уровень заголовка, 1 — верхний. `nil` — обычный абзац.
        public var headingLevel: Int?
        /// Готовый маркер списка: «1.», «2.1.», «•».
        public var marker: String?
        /// Весь текст абзаца скрыт (`w:vanish`) — Word его не показывает
        /// и не печатает.
        public var isHidden: Bool
        /// Ячейка таблицы, если абзац в ней.
        public var cell: Cell?
        /// Куда ведут гиперссылки абзаца.
        public var links: [String]
        /// Номера сносок, на которые абзац ссылается.
        public var footnotes: [String]
        /// Номера замечаний рецензентов, отмеченных в абзаце.
        public var comments: [String]
        /// Весь текст абзаца набран жирным.
        public var isBold: Bool
        /// Кегль, если он задан прямо в прогонах. `nil` — взят из стиля,
        /// и тогда сравнивать не с чем.
        public var size: Double?
        /// Строка оглавления (стиль «toc N»): в тексте документа она не
        /// нужна — те же заголовки стоят на своих местах.
        public var isTableOfContents: Bool

        public init(
            text: String, headingLevel: Int? = nil, marker: String? = nil,
            isHidden: Bool = false, cell: Cell? = nil,
            links: [String] = [], footnotes: [String] = [], comments: [String] = [],
            isBold: Bool = false, size: Double? = nil, isTableOfContents: Bool = false
        ) {
            self.isTableOfContents = isTableOfContents
            self.comments = comments
            self.isBold = isBold
            self.size = size
            self.text = text
            self.headingLevel = headingLevel
            self.marker = marker
            self.isHidden = isHidden
            self.cell = cell
            self.links = links
            self.footnotes = footnotes
        }

        /// Текст с маркером впереди: «3.2. Порядок расчётов».
        public var rendered: String {
            guard let marker, !marker.isEmpty else { return text }
            return "\(marker) \(text)"
        }
    }

    /// Замечание рецензента.
    public struct Comment: Hashable, Sendable {
        public var id: String
        public var author: String
        public var text: String

        public init(id: String, author: String, text: String) {
            self.id = id
            self.author = author
            self.text = text
        }
    }

    /// Где абзац стоит в таблице.
    public struct Cell: Hashable, Sendable {
        public var table: Int
        public var row: Int
        public var column: Int
        /// Продолжение объединённой вниз ячейки: своего значения у неё нет.
        public var isVerticalContinuation: Bool
        /// Сколько колонок сетки занимает ячейка.
        public var columnSpan: Int
        /// Строка помечена в файле как шапка таблицы — повторяемая на каждой
        /// странице (`w:tblHeader`).
        public var isHeaderRow: Bool

        public init(
            table: Int, row: Int, column: Int, isVerticalContinuation: Bool = false,
            columnSpan: Int = 1, isHeaderRow: Bool = false
        ) {
            self.table = table
            self.row = row
            self.column = column
            self.isVerticalContinuation = isVerticalContinuation
            self.columnSpan = max(1, columnSpan)
            self.isHeaderRow = isHeaderRow
        }
    }

    public struct Document: Sendable {
        public var paragraphs: [Paragraph]
        /// Колонтитулы: у документа их обычно один-два, и место им перед текстом.
        public var headers: [String]
        public var footers: [String]
        /// Номер сноски → её текст.
        public var footnotes: [String: String]
        /// Комментарии рецензентов — по порядку номеров.
        public var comments: [Comment]
        /// Есть ли в документе принятые правки.
        public var hasRevisions: Bool
        /// Комментарии в файле есть, а прочитать их не удалось.
        public var commentsUnreadable: Bool
        public var hasTables: Bool
        /// Сколько абзацев целиком скрыто.
        public var hiddenParagraphs: Int
    }
}

extension DocxPartsReader {
    public typealias Paragraph = WordParts.Paragraph
    public typealias Comment = WordParts.Comment
    public typealias Cell = WordParts.Cell
    public typealias Document = WordParts.Document
}

extension DocPartsReader {
    public typealias Paragraph = WordParts.Paragraph
    public typealias Comment = WordParts.Comment
    public typealias Cell = WordParts.Cell
    public typealias Document = WordParts.Document
}
