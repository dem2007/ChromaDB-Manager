import Foundation

/// Замечания и сноски OpenDocument — из `content.xml`, а не из импортёра
///.
///
/// Системный импортёр отдаёт тело документа и **номер** сноски, но не её
/// текст, а замечаний не отдаёт вовсе — та же беда, что была у `.docx`
/// до. Проверено на собранном файле: «Оплата производится по факту1
/// поставки», и ни слова из самой сноски.
///
/// `.odt` — тот же ZIP, читалка частей у проекта есть, а разметка описана
/// стандартом: `office:annotation` для замечания, `text:note` для сноски.
/// Поэтому здесь берётся только то, чего нет в тексте: тело документа
/// по-прежнему собирает импортёр.
public struct ODTPartsReader {
    /// То, что импортёр не отдал.
    public struct Extras: Sendable {
        public var comments: [WordParts.Comment] = []
        /// Номер сноски → её текст. Номер — тот же, что виден в тексте.
        public var footnotes: [(id: String, text: String)] = []
        /// В документе есть принятые правки: индексируется финальная редакция.
        public var hasRevisions = false

        public var isEmpty: Bool { comments.isEmpty && footnotes.isEmpty }
    }

    private let content: Data

    public init?(url: URL) {
        guard let reader = try? ZIPContainerReader(url: url),
              let content = try? reader.read("content.xml")
        else { return nil }
        self.content = content
    }

    /// `nil` — разметка не разобралась; тогда оговорка остаётся прежней,
    /// и это честнее, чем молчание.
    public func read() -> Extras? {
        guard let document = try? XMLDocument(data: content, options: []),
              let root = document.rootElement()
        else { return nil }

        var result = Extras()
        var counter = 0
        func walk(_ element: XMLElement) {
            switch element.localName {
            case "annotation":
                // Замечание рецензента — такой же написанный человеком текст,
                // как сноска: «уточнить срок» ищут теми же словами.
                let author = text(ofFirst: "creator", in: element)
                let body = paragraphs(of: element, skipping: ["creator", "date"])
                if !body.isEmpty {
                    counter += 1
                    result.comments.append(WordParts.Comment(
                        id: element.attribute(forName: "office:name")?.stringValue ?? "\(counter)",
                        author: author, text: body
                    ))
                }
                return
            case "note":
                let citation = text(ofFirst: "note-citation", in: element)
                let body = (element.elements(forLocalName: "note-body").first).map {
                    paragraphs(of: $0, skipping: [])
                } ?? ""
                if !body.isEmpty {
                    result.footnotes.append((id: citation.isEmpty ? "\(result.footnotes.count + 1)" : citation, text: body))
                }
                return
            case "tracked-changes":
                result.hasRevisions = true
                return
            default:
                break
            }
            for child in element.children ?? [] {
                guard let child = child as? XMLElement else { continue }
                walk(child)
            }
        }
        walk(root)
        return result
    }

    // MARK: - Мелочи разбора

    /// Текст абзацев элемента, кроме служебных полей.
    private func paragraphs(of element: XMLElement, skipping: Set<String>) -> String {
        var pieces: [String] = []
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            guard !skipping.contains(child.localName ?? "") else { continue }
            let piece = (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
        }
        return pieces.joined(separator: " ")
    }

    private func text(ofFirst localName: String, in element: XMLElement) -> String {
        element.elements(forLocalName: localName).first
            .flatMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}

private extension XMLElement {
    /// Дочерние элементы по имени **без** пространства имён: в OpenDocument
    /// один и тот же элемент пишут и как `text:p`, и как `p`, и сравнивать
    /// полное имя значит зависеть от того, кто сохранил файл.
    func elements(forLocalName name: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in children ?? [] {
            guard let child = child as? XMLElement else { continue }
            if child.localName == name { result.append(child) }
            result.append(contentsOf: child.elements(forLocalName: name))
        }
        return result
    }
}
