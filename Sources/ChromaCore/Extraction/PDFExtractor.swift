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
    /// 8 — записи нумерованной таблицы — одной строкой, и через границу
    /// страницы тоже; абзац, перенесённый на следующую страницу, — одним
    /// абзацем; скан внутри документа распознаётся в родном разрешении
    ///.
    ///
    /// 7 — таблицы с рамкой собираются по линиям рамки, с объединёнными
    /// ячейками и продолжением на следующей странице; строка, выровненная
    /// по ширине, больше не режется на «колонки» по словам; перенос внутри
    /// ячейки не рвёт таблицу; текст вокруг таблиц сшивается в абзацы;
    /// скан внутри документа распознаётся; штамп и номер страницы на краях
    /// уходят; страница, где рамки знаков не совпадают с текстом, идёт
    /// текстом PDFKit. Текст меняется — предложит перечитать.
    ///
    /// 6 — рост знака считается по буквам, а не по отточию оглавления
    ///: страница с точками-заполнителями рассыпалась на слоги и
    /// уходила в базу markdown-таблицей из них. Текст меняется —
    /// обязано предложить перечитать файлы.
    ///
    /// 5 — знаки препинания возвращены в свою строку таблицы:
    /// «12 345 678,00» приходило как «12 345 678 00», а номер позиции
    /// «11.1» — как «11 1». Меняется сам текст, значит обязано
    /// предложить перечитать файлы.
    ///
    /// 4 — адреса ссылок доходят до метаданных чанка: раньше они
    /// терялись целиком, потому что живут аннотациями, а не текстом.
    ///
    /// 3 — таблицы собираются по координатам знаков: строки и колонки
    /// возвращаются на место, страница с таблицей не сшивается в абзацы,
    /// и появляется `has_tables`.
    ///
    /// 2 — сшивка строк в абзацы меняет сам текст, а не только
    /// оговорки к нему: обязано предложить перечитать файлы.
    ///
    /// 11 — символы шрифтов Symbol и особые пробелы нормализуются до сшивки
    /// строк, оглавление не индексируется.
    ///
    /// 12 — пробел из текста страницы — граница слова и там, где между
    /// знаками нет промежутка: в ужатых ячейках таблиц слова склеивались
    /// («Наименованиехарактеристики»).
    ///
    /// 13 — подпись во всю ширину таблицы один раз; ячейка,
    /// разорванная страницей, — одной строкой.
    ///
    /// 14 — маркеры Wingdings узнаются по шрифту знака, знаки табличных
    /// страниц нормализуются до сборки, строки бланка с подчёркиваниями
    /// не считаются оглавлением, ссылки встают на своё место.
    public let version = 14

    /// Below this many characters per page on average, a PDF is a picture of
    /// text rather than an empty document — the distinction decides whether the
    /// user is told «turn on OCR» or «there is nothing here».
    public static let scanCharactersPerPage = 20

    /// Порог «почти пустого слоя» применяется только к многостраничным
    /// документам.
    ///
    /// Одностраничный PDF с одной строкой — расписка, справка, титул — это
    /// нормальный короткий документ, и отправлять его в «требуют решения»
    /// значило бы терять текст, который есть. А вот три страницы, на которых
    /// всего три знака, никто как текст не набирал.
    public static let minimumPagesForScanCheck = 2

    /// Доля страницы под картинкой, с которой страница без текста считается
    /// сканом, а не пустой страницей с логотипом.
    static let scanImageCoverage = 0.5

    /// Таблица, продолженная на следующей странице, получает свою шапку
    ///, а строки без номера в её начале — к своей записи на
    /// предыдущей странице.
    ///
    /// Word повторяет шапку на каждой странице только по просьбе, и обычно
    /// её не просят: продолжение таблицы начинается сразу со строк данных.
    /// Markdown же считает шапкой первую строку, и на второй странице прайса
    /// названиями колонок становились значения первой позиции, а куски
    /// оттуда расходились по базе вовсе без названий колонок. Продолжение
    /// узнаётся по рамке: те же границы колонок, что у последней таблицы
    /// предыдущей страницы, и между ними — не больше колонтитула.
    /// - Parameter skipping: страницы, которые выводятся текстом OCR, а не
    ///   своими блоками: перенесённое в их блоки не попало бы в текст, и
    ///   продолжение через них не ищется.
    static func continueTables(
        _ blocks: inout [Int: [TableGeometry.PageBlock]], pageCount: Int, skipping: Set<Int> = []
    ) {
        func isTable(_ block: TableGeometry.PageBlock) -> Bool {
            if case .table = block { return true } else { return false }
        }
        func textLines(_ range: ArraySlice<TableGeometry.PageBlock>) -> Int {
            range.reduce(0) { count, block in
                if case .text(let lines) = block { return count + lines.count }
                return count
            }
        }
        var previous: (header: [String], edges: [Double], page: Int, block: Int)?
        for index in 0..<pageCount {
            guard !skipping.contains(index), var found = blocks[index] else { previous = nil; continue }
            let carried = previous
            var emptied = false
            if let prior = previous,
               let first = found.firstIndex(where: isTable),
               textLines(found[..<first]) <= 2,
               case .table(var rows, let edges?) = found[first],
               edges.count == prior.edges.count,
               zip(edges, prior.edges).allSatisfy({ abs($0 - $1) <= 3 }),
               let head = rows.first, head.count == prior.header.count {
                if head != prior.header { rows.insert(prior.header, at: 0) }
                // Запись, разорванная страницей: строки без номера
                // в начале продолжения — части последней записи предыдущей
                // страницы. Сервер внизу листа, его комплектующие — на
                // следующем. Строки переносятся как есть; сводятся записи
                // потом, при выводе таблицы.
                if var earlier = blocks[prior.page], case .table(var before, let beforeEdges) = earlier[prior.block],
                   before.count >= 2, let layout = TableRecords.layout(of: before + rows.dropFirst()),
                   let head = before.lastIndex(where: { TableRecords.isNumber(TableRecords.padded($0, to: prior.header.count)[layout.number]) }),
                   head > 0 {
                    let width = prior.header.count
                    let record = TableRecords.padded(before[head], to: width)
                    var end = 1
                    while end < rows.count,
                          TableRecords.isPart(TableRecords.padded(rows[end], to: width), of: record, layout: layout) {
                        end += 1
                    }
                    if end > 1 {
                        // Сразу за частями записи, а не в конец: под ней
                        // бывает итог страницы, и после него части к записи
                        // уже не приклеились бы.
                        var at = head + 1
                        while at < before.count,
                              TableRecords.isPart(TableRecords.padded(before[at], to: width), of: record, layout: layout) {
                            at += 1
                        }
                        before.insert(contentsOf: rows[1..<end], at: at)
                        earlier[prior.block] = .table(rows: before, edges: beforeEdges)
                        blocks[prior.page] = earlier
                        rows.removeSubrange(1..<end)
                    }
                }
                // Ячейка, разорванная страницей: у таблицы без номеров
                // записи по номеру не узнать, и хвост значения приходил
                // отдельной строкой без названия параметра.
                if rows.count > 1, var earlier = blocks[prior.page],
                   case .table(var before, let beforeEdges) = earlier[prior.block],
                   before.count >= 2, let last = before.last, continuesCells(of: last, with: rows[1]) {
                    before[before.count - 1] = joiningCells(of: last, with: rows[1])
                    earlier[prior.block] = .table(rows: before, edges: beforeEdges)
                    blocks[prior.page] = earlier
                    rows.remove(at: 1)
                }
                if rows.count > 1 {
                    found[first] = .table(rows: rows, edges: edges)
                } else {
                    found.remove(at: first)
                    emptied = true
                }
                blocks[index] = found
            }
            previous = nil
            if let last = found.lastIndex(where: isTable),
               textLines(found[(last + 1)...]) <= 3,
               case .table(let rows, let edges?) = found[last], let header = rows.first {
                previous = (header, edges, index, last)
            } else if emptied, textLines(found[...]) <= 3 {
                // Вся таблица страницы ушла к записи на предыдущей: позиция
                // длиннее страницы. Продолжение на следующей — всё ещё та же
                // таблица той же страницы.
                previous = carried
            }
        }
    }

    /// Первая строка продолжения — хвост ячеек последней строки предыдущей
    /// страницы.
    ///
    /// Строка таблицы, длиннее остатка страницы, рвётся: «Возможности портов
    /// | …checksum assist, PQS,» внизу одной страницы и
    /// «| Parity Mode, Adaptive event batching); …» вверху
    /// следующей. Узнаётся по двум признакам сразу:
    /// - первая ячейка продолжения пуста — название параметра осталось на
    ///   предыдущей странице;
    /// - каждая заполненная его ячейка продолжает ячейку, оборванную на
    ///   полуслове: та кончается запятой, дефисом, тире, двоеточием,
    ///   открывающей скобкой или в ней скобка открыта и не закрыта.
    ///
    /// Одной пустой первой ячейки мало: так же выглядит и следующая запись
    /// под названием, объединённым вниз через страницу («Количество ядер
    /// процессора | ≥ 2», а на новой странице «|  | ≥ 4»), — и склеить её с
    /// предыдущей значило бы слить две записи в одну.
    static func continuesCells(of last: [String], with next: [String]) -> Bool {
        let width = max(last.count, next.count)
        let last = TableRecords.padded(last, to: width)
        let next = TableRecords.padded(next, to: width)
        guard width >= 2, next[0].trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let filled = next.indices.filter { !next[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filled.isEmpty else { return false }
        return filled.allSatisfy { isCutOff(last[$0]) }
    }

    /// Значение оборвано на полуслове. Прочерк «-» или «—» в ячейке — это
    /// «нет», а не обрыв: до знака должно стоять слово или число.
    static func isCutOff(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let end = trimmed.last, trimmed.dropLast().contains(where: { $0.isLetter || $0.isNumber }) else {
            return false
        }
        if ",-–—:(".contains(end) { return true }
        return trimmed.filter { $0 == "(" }.count > trimmed.filter { $0 == ")" }.count
    }

    /// Последняя строка вместе с хвостами своих ячеек. Перенос слова по
    /// дефису («интер-» и «фейсов») склеивается без пробела, как и строки
    /// внутри ячейки; тире перечисления («assist -» и «XFER») — с пробелом:
    /// перед ним не буква, а пробел.
    static func joiningCells(of last: [String], with next: [String]) -> [String] {
        let width = max(last.count, next.count)
        var result = TableRecords.padded(last, to: width)
        let next = TableRecords.padded(next, to: width)
        for column in result.indices {
            let tail = next[column].trimmingCharacters(in: .whitespaces)
            guard !tail.isEmpty else { continue }
            let head = result[column].trimmingCharacters(in: .whitespaces)
            let hyphenated = head.hasSuffix("-") && head.dropLast().last?.isLetter == true && tail.first?.isLetter == true
            result[column] = hyphenated ? head + tail : head + " " + tail
        }
        return result
    }

    public init() {}

    public func canHandle(_ type: UTType) -> Bool { type.conforms(to: .pdf) }

    /// С распознаванием — без срока на файл, как у `VisionOCRExtractor`
    ///: страницы-сканы распознаются прямо здесь, со сроком на каждую,
    /// и минута на весь файл обрывала документ с несколькими сканами целиком
    /// — хотя без распознавания он отдал бы хотя бы текстовый слой.
    public func timeout(for options: ExtractionOptions) -> TimeInterval {
        options.ocrEnabled ? 0 : options.perFileTimeout
    }

    /// Шрифты знаков частной области на странице — по смещению в UTF-16
    ///.
    ///
    /// Такой знак — код символьного шрифта, и что он значит, решает шрифт:
    /// `\u{F076}` в Symbol — «ϖ», в Wingdings — маркер «❖». Без шрифта код
    /// читался по Symbol, и пункты списков Word с маркерами Wingdings
    /// приходили с греческой буквой впереди — и не узнавались пунктами.
    /// Атрибуты страницы читаются только там, где такие знаки есть.
    static func symbolFonts(of page: PDFPage, string: String) -> [Int: String] {
        guard string.contains(where: TextNormalization.isSymbolFontCode),
              let attributed = page.attributedString, attributed.string == string else { return [:] }
        var result: [Int: String] = [:]
        let utf16 = Array(string.utf16)
        for (offset, unit) in utf16.enumerated() where (0xF020...0xF0FF).contains(unit) {
            if let font = attributed.attribute(.font, at: offset, effectiveRange: nil) as? NSFont {
                result[offset] = font.fontName
            }
        }
        return result
    }

    /// Текст страницы с нормализованными знаками.
    static func normalizedText(of page: PDFPage) -> String {
        let string = page.string ?? ""
        return TextNormalization.normalized(string, fonts: symbolFonts(of: page, string: string))
    }

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

        // Страницы собираются в массив, а не приклеиваются к строке сразу:
        // судьбу дефиса на конце строки решает словарь **всего** документа
        //, а он не построится, пока не прочитаны все страницы.
        var raw: [String] = []
        /// Страницы, собранные по координатам знаков и по рамке
        ///: таблицы на них уже разобраны, и ни сшивать их строки, ни
        /// доверять порядку строк от PDFKit на них не нужно. Текст между
        /// таблицами сшивается потом — со словарём документа.
        var blocks: [Int: [TableGeometry.PageBlock]] = [:]
        /// Страницы, где таблица была, а собрать её не вышло.
        var unassembled = 0
        raw.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            // Знаки символьных шрифтов и особые пробелы — до сшивки строк
            //: маркер `\u{F0B7}` иначе не узнавался маркером, и пункты
            // списка сливались в один абзац.
            raw.append((document.page(at: index).map(Self.normalizedText) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        /// Строки у края листа собранных страниц — среди них ищется
        /// оформление.
        var margins: [Int: [String]] = [:]
        /// Разбор линий и картинок — один на страницу: он нужен и сборке
        /// таблиц, и поиску сканов, и масштабу распознавания, а каждый
        /// проход читает весь поток страницы.
        var scanned: [Int: PDFRulings] = [:]
        func rulings(_ index: Int, _ page: PDFPage) -> PDFRulings {
            if let known = scanned[index] { return known }
            let found = PDFRulings.scan(page)
            scanned[index] = found
            return found
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let assessed = PDFPageTables.assess(page) { rulings(index, $0) }
            if let found = assessed.blocks {
                blocks[index] = found
                margins[index] = assessed.margins
            }
            if assessed.unassembledTable { unassembled += 1 }
        }

        // Знаков на страницу — по текстовому слою, до распознавания
        // отдельных страниц.
        //
        // Раньше эта величина считалась только внутри `guard`, куда попадали
        // лишь документы с **нулевым** текстом, и потому она всегда равнялась
        // нулю: порог не работал ни разу. Скан с колонтитулом-номером страницы
        // (замер: 2 файла из 400, один из них — 3 страницы по одному знаку)
        // проходил проверку и уходил в базу горстью цифр, а OCR никто
        // не предлагал.
        let layer = raw.reduce(0) { $0 + $1.count }
        let perPage = document.pageCount > 0 ? layer / document.pageCount : 0
        let looksLikeScan = document.pageCount >= Self.minimumPagesForScanCheck
            && perPage < Self.scanCharactersPerPage
        guard layer > 0, !looksLikeScan else {
            throw ExtractionError.noTextLayer(
                looksLikeScan: document.pageCount > 0 && perPage < Self.scanCharactersPerPage
            )
        }

        // Скан внутри документа с текстовым слоем: страница без
        // текста, которую почти целиком закрывает картинка. Раньше такая
        // страница выпадала молча — распознавание включалось, только если
        // пуст весь документ. Живой случай: письмо с КП, где первая страница
        // набрана, а вторая — скан расчёта на несколько миллиардов рублей.
        //
        // Текст страницы считается без оформления: скан, подписанный через
        // Диадок, несёт штамп текстом поверх картинки — около сотни знаков, —
        // и по одному только счёту знаков он сканом не считался.
        let furniture = PDFFurniture(pages: raw)
        var recognised: [Int: String] = [:]
        /// Распознанные страницы, где нашлась таблица.
        var recognisedTables: Set<Int> = []
        var warnings: [ExtractionWarning] = []
        let scans = (0..<document.pageCount).filter { index in
            let own = raw[index].components(separatedBy: .newlines)
                .filter { !furniture.isRepeated($0) }
                .reduce(0) { $0 + $1.trimmingCharacters(in: .whitespaces).count }
            guard own < Self.scanCharactersPerPage, let page = document.page(at: index) else { return false }
            return rulings(index, page).imageCoverage >= Self.scanImageCoverage
        }
        if !scans.isEmpty {
            let languages = options.ocrEnabled ? try? VisionOCRExtractor.resolvedLanguages(options.ocrLanguages) : nil
            if let languages {
                var confidence = 0.0
                var weight = 0.0
                /// Сканы-листы, у которых прочитались не все плитки.
                var partial: [Int] = []
                for (number, index) in scans.enumerated() {
                    try Task.checkCancellation()
                    options.progress?(ExtractionProgress(stage: .recognising, unit: number + 1, total: scans.count))
                    guard let page = document.page(at: index),
                          let result = try? await VisionOCRExtractor.recognisePage(
                            page, languages: languages, timeout: options.ocrPageTimeout,
                            rulings: rulings(index, page)
                          ) else { continue }
                    let text = result.blocks.map { TableGeometry.render($0, vocabulary: .empty) }
                        ?? PDFTextReflow.page(TextNormalization.normalized(result.text))
                    // Пустая страница названа ниже нераспознанной — «не
                    // целиком» о ней было бы второй, противоречащей оговоркой.
                    guard !text.isEmpty else { continue }
                    if result.unreadTiles > 0 { partial.append(index + 1) }
                    recognised[index] = text
                    if result.hasTable { recognisedTables.insert(index) }
                    confidence += result.confidence * Double(result.text.count)
                    weight += Double(result.text.count)
                }
                if !recognised.isEmpty {
                    let average = weight > 0 ? confidence / weight : 0
                    let list = recognised.keys.sorted().map { String($0 + 1) }.joined(separator: ", ")
                    warnings.append(.other(String(localized: "страницы без текстового слоя распознаны OCR (\(list)), уверенность \(Int((average * 100).rounded()))% — ошибки распознавания возможны")))
                }
                let missed = scans.count - recognised.count
                if missed > 0 {
                    warnings.append(.other(String(localized: "страниц-сканов не распознано: \(missed)")))
                }
                warnings += VisionOCRExtractor.partialPagesWarning(partial)
            } else {
                warnings.append(.other(String(localized: "страниц без текстового слоя (скан): \(scans.count) — их текст не извлечён; включите распознавание у источника")))
            }
        }

        // Оформление: у страниц текстом PDFKit — повтор в первых и последних
        // строках, у собранных — повтор у края листа. По порядку страниц:
        // первое появление строки остаётся.
        let edges = PDFFurniture(margins: Array(margins.values))
        var seenFurniture: Set<String> = []
        var seenEdges: Set<String> = []
        var cleanedRaw: [Int: String] = [:]
        // Оглавление — не текст документа: его строки убираются
        // блоком, а страница, которой оно кончилось, передаёт это следующей.
        var contentsContinues = false
        var contentsLines = 0
        for index in 0..<document.pageCount where recognised[index] == nil {
            if let found = blocks[index] {
                blocks[index] = edges.removing(
                    margins[index] ?? [], from: furniture.cleaned(found, seen: &seenFurniture), seen: &seenEdges
                )
                contentsContinues = false
            } else {
                let lines = furniture.cleaned(raw[index].components(separatedBy: .newlines), seen: &seenFurniture)
                let contents = PDFContents.removing(lines, continuing: contentsContinues)
                contentsContinues = contents.endsInContents
                contentsLines += contents.removed
                cleanedRaw[index] = contents.lines.joined(separator: "\n")
            }
        }
        if contentsLines > 0 {
            warnings.append(.other(String(localized: "оглавление не индексируется: \(contentsLines.plainDigits) строк — те же заголовки есть в тексте документа")))
        }
        Self.continueTables(&blocks, pageCount: document.pageCount, skipping: Set(recognised.keys))

        let vocabulary = PDFTextReflow.vocabulary(ofPages: raw)
        var text = ""
        var pageStarts: [Int] = []
        var pages: [String] = []
        // Счётчик вместо `text.count`: у строки это не поле, а обход, и на
        // 451-страничном файле пересчёт на каждой странице стоил 1.52 с
        // против 0.007 с со счётчиком.
        var length = 0
        var lastPage: String?
        for (index, page) in raw.enumerated() {
            // На табличной странице строки таблицы не сшиваются: строка там —
            // строка таблицы, и склеить её со следующей значило бы смешать
            // две записи. Текст вокруг таблиц сшивается, как везде.
            let reflowed: String
            if let ocr = recognised[index] {
                reflowed = ocr
            } else if let found = blocks[index] {
                reflowed = TableGeometry.render(found, vocabulary: vocabulary)
            } else {
                reflowed = PDFTextReflow.page(cleanedRaw[index] ?? page, vocabulary: vocabulary)
            }
            pages.append(reflowed)
            guard !reflowed.isEmpty else {
                // An empty page still gets an offset, or every page after it
                // would be numbered one too low.
                pageStarts.append(length)
                // Пустая страница — граница: абзац через неё не склеивается.
                lastPage = nil
                continue
            }
            if length > 0 {
                // Абзац, перенесённый через границу страницы, — одним абзацем
                //.
                if let previous = lastPage,
                   let bridge = PDFTextReflow.bridge(previous, reflowed, vocabulary: vocabulary) {
                    text.removeLast(bridge.drop)
                    text += bridge.separator
                    length += bridge.separator.count - bridge.drop
                } else {
                    text += "\n\n"
                    length += 2
                }
            }
            lastPage = reflowed
            // **After** the separator, not before: the offset has to be where
            // this page's text actually begins. Recorded a line earlier, it
            // pointed at the tail of the previous page — which put the last two
            // characters of every page onto the next one, and made the first
            // line of a Keynote slide come out as the end of the slide before.
            pageStarts.append(length)
            text += reflowed
            length += reflowed.count
        }

        // Only trimmed page text is appended, and nothing is appended for an
        // empty page, so `text` never starts with whitespace — `sanitized` can
        // only trim the tail, and the page offsets collected above stay valid.
        guard let plainText = PlainTextExtractor.sanitized(text) else {
            throw ExtractionError.noTextLayer(looksLikeScan: false)
        }

        var (structure, source) = outline(
            of: document, pages: pages, pageStarts: pageStarts
        )
        // Без закладок — заголовки по виду строки.
        if source == .none {
            let found = PDFHeadings.detect(
                in: document, pages: pages, pageStarts: pageStarts, skipped: Set(recognised.keys)
            )
            if !found.isEmpty {
                structure = found
                source = .heuristic
            }
        }

        switch source {
        case .outline: break
        case .heuristic: warnings.append(.structureIsHeuristic)
        default: warnings.append(.noStructure)
        }

        let hasTables = !recognisedTables.isEmpty || blocks.values.contains { found in
            found.contains { if case .table = $0 { return true } else { return false } }
        }
        if hasTables { warnings.append(.tablesFlattened) }
        // Отдельная оговорка, и она о другом: не «оформление
        // потеряно», а «колонки не разделены». По такой странице нельзя
        // сказать, где цена, а где итог, — и агент, считающий по ней смету,
        // должен знать это до того, как посчитает.
        if unassembled > 0 { warnings.append(.tablesNotAssembled(pages: unassembled)) }

        return ExtractedDocument(
            plainText: plainText,
            structure: structure,
            pageCount: document.pageCount,
            pageStarts: pageStarts,
            links: Self.links(of: document, pages: pages, pageStarts: pageStarts),
            warnings: warnings,
            structureSource: source,
            containerFormat: "pdf",
            extractorID: id,
            extractorVersion: version,
            hasTables: hasTables,
            documentMetadata: options.includeDocumentMetadata ? metadata(of: document) : [:]
        )
    }

    // MARK: - Structure

    /// The table of contents, where the document has one.
    ///
    /// A real outline gives both the title and the page. Раньше заголовок
    /// и вставал в **начало** этой страницы — на том основании, что цель
    /// в PDF указывает на страницу, а не на смещение. Но заголовков
    /// на странице бывает несколько, и тогда все они получали один и тот же
    /// offset: `heading_path` для текста, стоящего **выше** второго заголовка,
    /// называл второй заголовок.
    ///
    /// Поэтому заголовок ищется в тексте своей страницы по названию, а начало
    /// страницы остаётся запасным ответом — для случая, когда в тексте его
    /// нет (шрифтовая надпись, картинка, другая формулировка в оглавлении).
    private func outline(
        of document: PDFDocument,
        pages: [String],
        pageStarts: [Int]
    ) -> ([DocumentNode], StructureSource) {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else {
            return ([], .none)
        }

        var nodes: [(node: DocumentNode, order: Int)] = []
        var order = 0
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty,
                   let page = child.destination?.page,
                   let pageIndex = document.index(for: page) as Int?,
                   pageIndex >= 0, pageIndex < pageStarts.count {
                    nodes.append((DocumentNode(
                        level: level,
                        title: title,
                        start: pageStarts[pageIndex] + offset(of: title, in: pages[safe: pageIndex]),
                        pageNumber: pageIndex + 1
                    ), order))
                    order += 1
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 1)

        guard !nodes.isEmpty else { return ([], .none) }
        // Порядок обхода — вторым ключом, а не только `level`: сортировка
        // в Swift **не устойчива**, и два заголовка с одинаковым смещением
        // могли поменяться местами, то есть потерять порядок документа.
        let sorted = nodes.sorted {
            ($0.node.start, $0.node.level, $0.order) < ($1.node.start, $1.node.level, $1.order)
        }
        return (sorted.map(\.node), .outline)
    }

    /// Где на странице стоит заголовок. 0 — не нашёлся, значит начало страницы.
    private func offset(of title: String, in page: String?) -> Int {
        guard let page, !page.isEmpty else { return 0 }
        guard let range = page.range(
            of: title, options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return 0 }
        return page.distance(from: page.startIndex, to: range.lowerBound)
    }

    // MARK: - Ссылки

    /// Адреса, на которые ссылается документ, с их местом в тексте.
    ///
    /// **Две трудности, и обе настоящие.**
    ///
    /// Первая: в PDF ссылка — не текст, а аннотация с прямоугольником
    /// на странице, и `page.string` о ней не знает ничего. Переводит
    /// прямоугольник в место в тексте `characterIndex(at:)`.
    ///
    /// Вторая: место это — в **исходном** тексте страницы, а в документ
    /// уходит сшитый, и смещения у них разные. Перевод делается
    /// по счёту букв и цифр: сшивка меняет пробелы, переводы строк и дефисы
    /// переноса, а буквы и цифры оставляет все и в том же порядке — это
    /// не предположение, а то, что проверяет живой тест на 721 странице.
    ///
    /// На **табличной** странице текст собран не сшивкой, а заново
    /// по координатам знаков, и порядок там строится построчно по таблице —
    /// счёт букв на ней точен не всегда. Живой замер общей точности: 97%
    /// на 4133 ссылках, и табличные страницы в это число входят.
    ///
    /// **Почему не `characterIndex(at:)`, которым это делается в одну строку.**
    /// Он отвечает про точку, а прямоугольник ссылки шире подписи и обычно
    /// накрывает пустоту вокруг букв. Замер: на 337 ссылках он попал в подпись
    /// **шесть раз**, а в остальных вернул `Int.max` — не `-1`, как ждёшь
    /// от «не нашлось», отчего проверка на отрицательное значение его
    /// и пропускала. Обход прямоугольников знаков попадает на тех же файлах
    /// в подпись почти всегда.
    static func links(
        of document: PDFDocument, pages: [String], pageStarts: [Int]
    ) -> [DocumentLink] {
        var result: [DocumentLink] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  index < pages.count, index < pageStarts.count else { continue }
            let original = page.string ?? ""
            guard !original.isEmpty else { continue }

            let annotations = page.annotations.compactMap { annotation -> (CGRect, String)? in
                guard let action = annotation.action as? PDFActionURL, let url = action.url
                else { return nil }
                return (annotation.bounds, url.absoluteString)
            }
            guard !annotations.isEmpty else { continue }

            // Один проход по знакам страницы на все её ссылки сразу: страниц
            // со ссылками мало, а перебирать знаки заново на каждую ссылку —
            // это множить самую дорогую часть на самую частую.
            var firstCharacter = [Int?](repeating: nil, count: annotations.count)
            var remaining = annotations.count
            for character in 0..<min(page.numberOfCharacters, original.count) {
                let bounds = page.characterBounds(at: character)
                for (position, annotation) in annotations.enumerated()
                where firstCharacter[position] == nil && annotation.0.intersects(bounds) {
                    firstCharacter[position] = character
                    remaining -= 1
                }
                if remaining == 0 { break }
            }

            let map = significantOffsets(
                original: original, reflowed: pages[index], fonts: symbolFonts(of: page, string: original)
            )
            let inText = textOffsets(ofBounds: firstCharacter.compactMap { $0 }, in: original)
            for (position, annotation) in annotations.enumerated() {
                // Ссылка, под которой не нашлось ни одного знака, — это
                // ссылка на картинке. Места в тексте у неё нет, и выдумывать
                // его нельзя: адрес достался бы чужому чанку.
                guard let character = firstCharacter[position], let offset = inText[character] else { continue }
                result.append(DocumentLink(
                    url: annotation.1, start: pageStarts[index] + map(offset)
                ))
            }
        }
        return result
    }

    /// Номера рамок знаков — в смещения текста страницы.
    ///
    /// Рамки `characterBounds` нумеруются без переводов строки, которые
    /// PDFKit вставляет в текст сам (так же считает `PDFPageTables.words`).
    /// Номер рамки, взятый за смещение в тексте, отставал на строку за каждую
    /// строку выше, и ссылка с сороковой строки вставала на сорок знаков
    /// раньше — нередко в предыдущий чанк.
    static func textOffsets(ofBounds wanted: [Int], in text: String) -> [Int: Int] {
        let targets = Set(wanted)
        guard let last = targets.max() else { return [:] }
        var result: [Int: Int] = [:]
        var bounds = 0
        for (offset, character) in text.enumerated() {
            if character.isNewline { continue }
            if targets.contains(bounds) { result[bounds] = offset }
            if bounds >= last { break }
            bounds += 1
        }
        return result
    }

    /// Сколько значимых знаков сверяется, чтобы найти место в сшитом тексте.
    static let anchorLength = 12

    /// Перевод смещения из исходного текста страницы в сшитый — по счёту
    /// значимых знаков.
    ///
    /// Счёт верен, пока сшитый текст несёт все буквы исходного. Но
    /// колонтитул и оглавление из текста страницы убираются,
    /// и всё ниже убранного съезжало на его длину. Поэтому место
    /// проверяется по самим знакам: дюжина значимых знаков от смещения
    /// ищется в сшитом тексте, и из найденных берётся ближайшее к счёту.
    /// Не нашлось — остаётся счёт.
    ///
    /// Возвращает функцию, а не таблицу: обход обоих текстов делается один
    /// раз на страницу, а спрашивают его столько раз, сколько на странице
    /// ссылок, — обычно один-два.
    /// - Parameter fonts: шрифты знаков частной области исходного текста
    ///   по смещению в UTF-16 (`symbolFonts`).
    static func significantOffsets(original: String, reflowed: String, fonts: [Int: String] = [:]) -> (Int) -> Int {
        // Знак исходного текста — таким, каким он стал в сшитом, и со
        // шрифтом, как в сшитом: маркер Wingdings там — «❖», а без
        // шрифта он читался буквой Symbol, и счёт съезжал на число маркеров
        // выше ссылки (ревью…).
        func significant(_ character: Character, at offset: Int) -> Character? {
            guard let normalized = TextNormalization.replacement(for: character, font: fonts[offset]),
                  normalized.isLetter || normalized.isNumber else { return nil }
            return normalized
        }
        // Сколько значимых знаков стоит до каждого смещения исходного текста.
        var significantBefore: [Int] = [0]
        significantBefore.reserveCapacity(original.count + 1)
        var originalLetters: [Character] = []
        var utf16 = 0
        for character in original {
            if let letter = significant(character, at: utf16) { originalLetters.append(letter) }
            significantBefore.append(originalLetters.count)
            utf16 += character.utf16.count
        }
        // И где в сшитом тексте начинается n-й значимый знак.
        var offsetOfSignificant: [Int] = []
        var reflowedLetters: [Character] = []
        for (offset, character) in reflowed.enumerated() where character.isLetter || character.isNumber {
            offsetOfSignificant.append(offset)
            reflowedLetters.append(character)
        }

        func matches(_ from: Int, at position: Int, length: Int) -> Bool {
            guard position >= 0, position + length <= reflowedLetters.count else { return false }
            for step in 0..<length where reflowedLetters[position + step] != originalLetters[from + step] {
                return false
            }
            return true
        }

        return { index in
            let clamped = max(0, min(index, significantBefore.count - 1))
            var position = significantBefore[clamped]
            let length = min(anchorLength, originalLetters.count - position)
            if length > 0, !matches(position, at: position, length: length) {
                var best: Int?
                for candidate in 0...max(0, reflowedLetters.count - length)
                where matches(position, at: candidate, length: length) {
                    if best.map({ abs(candidate - position) < abs($0 - position) }) ?? true { best = candidate }
                }
                if let best { position = best }
            }
            guard position < offsetOfSignificant.count else { return reflowed.count }
            return offsetOfSignificant[position]
        }
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
