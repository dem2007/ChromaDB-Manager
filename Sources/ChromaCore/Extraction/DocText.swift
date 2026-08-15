import Foundation

/// Сборка текста двоичного `.doc` — ступень 2.
///
/// Знаки уже собраны по таблице кусков, свойства прочитаны; здесь из них
/// получается то, с чем работает всё остальное приложение: абзацы, таблицы,
/// колонтитулы, сноски и замечания рецензентов.
///
/// Правила ровно те же, что у `.docx` (11.4.1), и это не совпадение: результат
/// у двух форматов обязан быть одинаковым, иначе один и тот же документ,
/// сохранённый дважды, даст в базе разные чанки.
extension DocPartsReader {
    /// Один абзац, каким он вышел из потока, — до того, как стал абзацем
    /// документа.
    struct RawParagraph {
        var text = ""
        var links: [String] = []
        /// Абзац закрыт меткой ячейки, а не знаком конца абзаца.
        var isCell = false
        /// Метка конца строки таблицы: текста не несёт, но закрывает строку.
        var isRowEnd = false
        var istd = 0
        var outline: Int?
        var isBold = false
        var size: Double?
        /// Абзац оказался пустым потому, что весь его текст скрыт.
        var isHidden = false
        /// Знаки документа, из которых абзац собран.
        ///
        /// Нужны ровно за тем, чтобы поставить сноску при её абзаце: таблица
        /// `plcffndRef` называет место ссылки знаком документа, а не абзацем,
        /// и без этого диапазона перевести одно в другое нечем.
        var cpRange: Range<Int> = 0..<0
        /// Номера сносок, на которые абзац ссылается.
        var footnotes: [String] = []
    }

    /// Всё, что нужно экстрактору, одним проходом по потокам.
    public func read() -> Document? {
        guard let text = characters() else { return nil }
        let characterProperties = characterRuns()
        let paragraphProperties = paragraphRuns()
        let styles = styleTable()

        func bounds(_ part: DocFIB.Subdocument) -> Range<Int> {
            let start = min(max(0, fib.start(of: part)), text.units.count)
            let end = min(start + fib.count(of: part), text.units.count)
            return start..<max(start, end)
        }

        func raw(_ range: Range<Int>) -> [RawParagraph] {
            rawParagraphs(
                in: range, text: text,
                characters: characterProperties, paragraphs: paragraphProperties, styles: styles
            )
        }

        /// Отдельная история — колонтитул, сноска, замечание — идёт одной
        /// строкой: разрывать её на абзацы незачем, это одна мысль.
        func story(_ start: Int, _ end: Int, within part: DocFIB.Subdocument) -> String {
            let base = fib.start(of: part)
            let range = min(max(0, base + start), text.units.count)..<min(max(0, base + end), text.units.count)
            guard range.lowerBound < range.upperBound else { return "" }
            return raw(range).map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        }

        var body = raw(bounds(.main))
        guard !body.isEmpty else { return nil }

        var document = Document(
            paragraphs: [], headers: [], footers: [], footnotes: [:], comments: [],
            hasRevisions: characterProperties.contains { $0.isDeleted || $0.isInserted },
            commentsUnreadable: false, hasTables: false, hiddenParagraphs: 0
        )

        // MARK: Сноски при своих абзацах
        //
        // Разбираются **до** сборки основного текста: номер сноски надо
        // поставить на абзац, а абзацы собираются один раз.
        var footnoteNumber = 0
        var footnoteByPosition: [Int: String] = [:]
        if let location = fib.location(of: .plcffndTxt) {
            let cps = Self.plcCPs(self.table, at: location.fc, lcb: location.lcb, cbData: 0)
            for index in 0..<max(0, cps.count - 1) {
                let content = story(cps[index], cps[index + 1], within: .footnotes)
                guard !content.isEmpty else { continue }
                footnoteNumber += 1
                document.footnotes["\(footnoteNumber)"] = content
                footnoteByPosition[index] = "\(footnoteNumber)"
            }
        }
        // `plcffndRef` называет место ссылки знаком документа; абзац, которому
        // этот знак принадлежит, известен из `cpRange`. Номер по порядку:
        // i-я ссылка отвечает i-й сноске в таблице текстов.
        if !footnoteByPosition.isEmpty, let location = fib.location(of: .plcffndRef) {
            let references = Self.plcCPs(self.table, at: location.fc, lcb: location.lcb, cbData: 2)
            let base = fib.start(of: .main)
            for (position, reference) in references.enumerated() {
                guard let id = footnoteByPosition[position] else { continue }
                let cp = base + reference
                guard let index = body.firstIndex(where: { $0.cpRange.contains(cp) }) else { continue }
                body[index].footnotes.append(id)
            }
        }

        // MARK: Основной текст и таблицы

        var table = 0
        var row = 0
        var column = 0
        var inTable = false
        for paragraph in body {
            if paragraph.isCell {
                inTable = true
                document.hasTables = true
                // Конец строки — это метка, а не ячейка: у неё нет ни текста,
                // ни места в строке, и считать её ячейкой значит добавлять
                // таблице пустую колонку справа.
                if paragraph.isRowEnd {
                    row += 1
                    column = 0
                    continue
                }
                document.paragraphs.append(assembled(
                    paragraph, styles: styles, cell: Cell(table: table, row: row, column: column)
                ))
                column += 1
                continue
            }
            if inTable {
                table += 1
                row = 0
                column = 0
                inTable = false
            }
            if paragraph.isHidden { document.hiddenParagraphs += 1 }
            guard !paragraph.text.isEmpty else {
                // Ссылка на сноску в пустом абзаце принадлежит тому, что было
                // до неё, — то же правило, что у `.docx`.
                if !paragraph.footnotes.isEmpty, !document.paragraphs.isEmpty {
                    document.paragraphs[document.paragraphs.count - 1].footnotes += paragraph.footnotes
                }
                continue
            }
            document.paragraphs.append(assembled(paragraph, styles: styles, cell: nil))
        }

        // MARK: Колонтитулы

        for header in headerStories() {
            let content = story(header.start, header.end, within: .headers)
            guard !content.isEmpty else { continue }
            // Чётная и нечётная страницы обычно несут один и тот же
            // колонтитул — в базе он нужен один раз.
            if header.isFooter {
                if !document.footers.contains(content) { document.footers.append(content) }
            } else if !document.headers.contains(content) {
                document.headers.append(content)
            }
        }

        // MARK: Сноски

        // Концевые сноски: своей таблицы ссылок для них не разбирается — их
        // подпоток известен из заголовка, и каждый абзац в нём и есть одна
        // сноска. Место ссылки на концевую остаётся неизвестным, поэтому
        // такая сноска по-прежнему уходит в конец документа.
        var number = footnoteNumber
        for paragraph in raw(bounds(.endnotes)) where !paragraph.text.isEmpty {
            number += 1
            document.footnotes["\(number)"] = paragraph.text
        }

        // MARK: Замечания рецензентов

        let authors = commentAuthors()
        if let location = fib.location(of: .plcfandTxt) {
            let cps = Self.plcCPs(self.table, at: location.fc, lcb: location.lcb, cbData: 0)
            for index in 0..<max(0, cps.count - 1) {
                let content = story(cps[index], cps[index + 1], within: .annotations)
                guard !content.isEmpty else { continue }
                document.comments.append(Comment(
                    id: "\(document.comments.count + 1)",
                    author: commentAuthor(at: index, among: authors),
                    text: content
                ))
            }
        }
        // Замечания в файле есть, а достать их не вышло — про это надо сказать,
        // а не молчать: молчание неотличимо от «их там нет».
        document.commentsUnreadable = document.comments.isEmpty && inventory().comments > 0

        // MARK: Надписи и врезки

        for paragraph in raw(bounds(.textboxes)) + raw(bounds(.headerTextboxes))
        where !paragraph.text.isEmpty {
            document.paragraphs.append(assembled(paragraph, styles: styles, cell: nil))
        }

        return document
    }

    /// Разобранный абзац — в абзац документа.
    private func assembled(_ paragraph: RawParagraph, styles: DocStyleTable, cell: Cell?) -> Paragraph {
        Paragraph(
            text: paragraph.text,
            // Уровень, поставленный прямо в абзаце, главнее стиля: человек
            // поставил его руками — то же правило, что у `.docx` (11.4.1).
            headingLevel: paragraph.outline.map { $0 + 1 } ?? styles.headingLevel(of: paragraph.istd),
            isHidden: false,
            cell: cell,
            links: paragraph.links,
            footnotes: paragraph.footnotes,
            isBold: paragraph.isBold,
            size: paragraph.size
        )
    }

    // MARK: - Абзацы из знаков

    func rawParagraphs(
        in range: Range<Int>, text: Characters,
        characters: [CharacterRun], paragraphs: [ParagraphRun], styles: DocStyleTable
    ) -> [RawParagraph] {
        guard range.lowerBound < range.upperBound else { return [] }
        var result: [RawParagraph] = []
        var units: [UInt16] = []
        var links: [String] = []
        /// Код поля: то, что стоит между началом поля и разделителем. Это
        /// не текст документа — это инструкция Word, и в базе ей делать
        /// нечего. Адрес гиперссылки берётся именно оттуда.
        var instruction: [UInt16]?
        var bold = 0
        var weighted = 0
        /// Знаки, про начертание и кегль которых прогон молчит: их свойства
        /// приходят из стиля абзаца, а стиль известен только в конце абзаца.
        var inheritedWeight = 0
        var invertedWeight = 0
        var inheritedSize = 0
        var sizes: [Int: Int] = [:]
        var hidden = 0

        var paragraphStart = range.lowerBound

        func close(at offset: Int, isCell: Bool, upTo index: Int) {
            let properties = Self.run(at: offset, in: paragraphs, start: { $0.start }, end: { $0.end })
            let style = styles.resolved(properties?.istd ?? 0)
            let styleIsBold = style?.isBold ?? false
            bold += styleIsBold ? inheritedWeight : invertedWeight
            if let halfPoints = style?.halfPoints, halfPoints > 0, inheritedSize > 0 {
                sizes[halfPoints, default: 0] += inheritedSize
            }

            var paragraph = RawParagraph()
            paragraph.text = String(decoding: units, as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.links = links
            paragraph.isCell = isCell
            paragraph.isRowEnd = properties?.isRowEnd ?? false
            paragraph.istd = properties?.istd ?? 0
            paragraph.outline = properties?.outline
            paragraph.isBold = weighted > 0 && bold == weighted
            paragraph.size = sizes.max { $0.value < $1.value }.map { Double($0.key) / 2 }
            paragraph.isHidden = paragraph.text.isEmpty && hidden > 0
            paragraph.cpRange = paragraphStart..<max(paragraphStart, index + 1)
            result.append(paragraph)
            paragraphStart = index + 1
            units = []
            links = []
            instruction = nil
            bold = 0
            weighted = 0
            inheritedWeight = 0
            invertedWeight = 0
            inheritedSize = 0
            sizes = [:]
            hidden = 0
        }

        for index in range {
            let unit = text.units[index]
            let offset = text.offsets[index]
            let run = Self.run(at: offset, in: characters, start: { $0.start }, end: { $0.end })
            // Правки считаются принятыми: удалённый текст в базу не идёт,
            // иначе документ попадёт в неё в двух редакциях сразу. Скрытого
            // текста для базы не существует по той же причине, по какой его
            // нет на бумаге.
            if run?.isDeleted == true { continue }
            // Знак конца абзаца закрывает абзац, даже если скрыт вместе с ним:
            // иначе скрытый абзац не пропадает, а **слипается** со следующим,
            // и посчитать пропущенное становится нечем.
            if unit != 0x0D, unit != 0x07, run?.isHidden == true {
                hidden += 1
                continue
            }

            switch unit {
            case 0x0D, 0x07:
                if run?.isHidden == true { hidden += 1 }
                close(at: offset, isCell: unit == 0x07, upTo: index)
            case 0x13:
                instruction = []
            case 0x14:
                if let instruction {
                    links.append(contentsOf: Self.hyperlinks(in: String(decoding: instruction, as: UTF16.self)))
                }
                instruction = nil
            case 0x15:
                instruction = nil
            default:
                if instruction != nil {
                    instruction?.append(unit)
                    continue
                }
                guard let visible = Self.visible(unit) else { continue }
                units.append(contentsOf: visible)
                guard visible != [0x20] else { continue }
                weighted += 1
                switch (run?.isBold, run?.invertsBold ?? false) {
                case (.some(true), _): bold += 1
                case (.some(false), _): break
                case (.none, true): invertedWeight += 1
                case (.none, false): inheritedWeight += 1
                }
                if let halfPoints = run?.halfPoints, halfPoints > 0 {
                    sizes[halfPoints, default: 0] += 1
                } else {
                    inheritedSize += 1
                }
            }
        }
        // Хвост без знака конца абзаца — тоже абзац: файл мог оборваться,
        // но прочитанное терять не за что.
        if !units.isEmpty {
            close(at: text.offsets[range.upperBound - 1], isCell: false, upTo: range.upperBound - 1)
        }
        return result
    }

    /// Знак текста — в знаки строки. `nil` — служебный знак, которому в базе
    /// делать нечего: метка сноски, картинка, мягкий перенос.
    static func visible(_ unit: UInt16) -> [UInt16]? {
        switch unit {
        case 0x09, 0x0A, 0x0B, 0x0C, 0xA0: return [0x20]
        case 0x1E: return [0x2D]
        case 0x1F: return nil
        case 0x00...0x08, 0x0E...0x1D: return nil
        default: return [unit]
        }
    }

    /// Адрес из кода поля. Кроме гиперссылки коды полей ничего полезного
    /// для поиска не несут — номера страниц, даты и оглавления в базе лишние.
    static func hyperlinks(in instruction: String) -> [String] {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("HYPERLINK") else { return [] }
        let parts = trimmed.components(separatedBy: "\"")
        guard parts.count >= 2 else { return [] }
        let address = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? [] : [address]
    }

    // MARK: - Авторы замечаний

    /// Имена авторов: сплошной список строк, каждая со своей длиной впереди.
    func commentAuthors() -> [String] {
        guard let location = fib.location(of: .grpXstAtnOwners),
              location.fc >= 0, location.fc + location.lcb <= table.count
        else { return [] }
        var result: [String] = []
        var offset = location.fc
        let end = location.fc + location.lcb
        while offset + 2 <= end {
            let length = Int(CFBContainerReader.u16(table, offset))
            offset += 2
            guard length >= 0, offset + length * 2 <= end else { break }
            let units = (0..<length).map { CFBContainerReader.u16(table, offset + $0 * 2) }
            result.append(String(decoding: units, as: UTF16.self))
            offset += length * 2
        }
        return result
    }

    /// Автор замечания номер `index`: в записи о нём лежит не имя, а номер
    /// в списке имён.
    func commentAuthor(at index: Int, among authors: [String]) -> String {
        guard let location = fib.location(of: .plcfandRef) else { return "" }
        let record = Self.plcRecord(table, at: location.fc, lcb: location.lcb, cbData: 30, index: index)
        guard !record.isEmpty else { return "" }
        let owner = Int(CFBContainerReader.u16(record, 20))
        return owner < authors.count ? authors[owner] : ""
    }
}
