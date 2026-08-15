import Foundation

/// Сборщик двоичных `.doc` для проверок.
///
/// Собирается здесь, а не берётся готовым файлом, ровно по той же причине,
/// что и `DocxFixture`: разбирается формат, а не чей-то документ, и каждая
/// ловушка — сжатый кусок, служебная история колонтитулов, замечание без
/// автора — должна быть выразима. Заодно это доказывает, что читалка OLE2
/// понимает и большие потоки в секторах файла, и мелкие в мини-потоке.
struct DocFixture {
    var paragraphs: [String] = ["Пробный абзац."]
    /// Верхний и нижний колонтитулы одного раздела.
    var header: String?
    var footer: String?
    var footnotes: [String] = []
    var comments: [(author: String, text: String)] = []
    var textboxes: [String] = []
    /// Куски текста в однобайтовой кодировке — так Word пишет всё, что
    /// укладывается в CP1251, и так лежит большинство настоящих файлов.
    var compressed = false
    /// Резать текст на куски по столько знаков. `nil` — один кусок на всё.
    var pieceLength: Int?
    /// Пустая история в конце списка сносок — так делает настоящий Word.
    var trailingEmptyFootnoteStory = false
    /// Стили: имя → уровень структуры (`sprmPOutLvl`), и какой абзац каким
    /// стилем набран.
    var styles: [DocStyle] = []
    /// Номер стиля для абзаца основного текста: 0 — «Обычный»,
    /// дальше по порядку из `styles`.
    var paragraphStyles: [Int: Int] = [:]
    /// Абзацы, удалённые правкой: текст в файле есть, а в документе его нет.
    var deletedParagraphs: Set<Int> = []
    /// Абзацы, скрытые от показа и печати.
    var hiddenParagraphs: Set<Int> = []
    /// Абзацы, набранные полужирным «наоборот, чем в стиле».
    var boldParagraphs: Set<Int> = []

    struct DocStyle {
        var name: String
        /// Встроенный номер стиля: 1…9 — «Заголовок 1»…«Заголовок 9».
        var sti: Int
        /// Уровень структуры 0…8, если стиль его задаёт.
        var outlineLevel: Int?
    }

    // MARK: - Сборка

    func build() -> Data {
        var characters: [UInt16] = []
        var counts: [Int] = Array(repeating: 0, count: 8)

        /// История: текст плюс знак конца абзаца.
        func append(_ text: String) -> Int {
            let before = characters.count
            characters.append(contentsOf: Array(text.utf16))
            characters.append(0x0D)
            return characters.count - before
        }

        // 1. Основной текст.
        for paragraph in paragraphs { counts[0] += append(paragraph) }

        // 2. Сноски.
        var footnoteBounds: [Int] = [0]
        for footnote in footnotes {
            counts[1] += append(footnote)
            footnoteBounds.append(counts[1])
        }
        if trailingEmptyFootnoteStory, !footnotes.isEmpty {
            counts[1] += append("")
            footnoteBounds.append(counts[1])
        }

        // 3. Колонтитулы: шесть служебных историй, потом шесть на раздел.
        var headerBounds: [Int] = [0]
        for _ in 0..<6 {
            counts[2] += append("")
            headerBounds.append(counts[2])
        }
        for story in ["", header ?? "", "", footer ?? "", "", ""] {
            counts[2] += append(story)
            headerBounds.append(counts[2])
        }

        // 4. Макросы (0), 5. замечания.
        var commentBounds: [Int] = [0]
        for comment in comments {
            counts[4] += append(comment.text)
            commentBounds.append(counts[4])
        }

        // 6. Концевые сноски (0), 7. надписи.
        for textbox in textboxes { counts[6] += append(textbox) }

        // MARK: Поток WordDocument

        let textStart = 2048
        var document = Data(count: textStart)
        var pieces: [(cp: Int, fc: Int, compressed: Bool)] = []
        let step = pieceLength ?? max(1, characters.count)
        var index = 0
        while index < characters.count {
            let end = min(characters.count, index + step)
            let slice = characters[index..<end]
            // Кусок пишется однобайтовым только если весь в него укладывается —
            // ровно то условие, по которому решает и Word.
            let fitsInBytes = compressed && slice.allSatisfy { $0 < 0x100 }
            pieces.append((cp: index, fc: document.count, compressed: fitsInBytes))
            if fitsInBytes {
                document.append(contentsOf: slice.map { UInt8($0) })
            } else {
                for unit in slice {
                    document.append(UInt8(unit & 0xFF))
                    document.append(UInt8(unit >> 8))
                }
            }
            index = end
        }
        if pieces.isEmpty { pieces.append((cp: 0, fc: document.count, compressed: false)) }

        // MARK: Поток таблиц

        var table = Data()
        var locations: [Int: (fc: Int, lcb: Int)] = [:]

        func place(_ index: Int, _ data: Data) {
            guard !data.isEmpty else { return }
            locations[index] = (fc: table.count, lcb: data.count)
            table.append(data)
        }

        // Таблица кусков.
        var plcPcd = Data()
        for piece in pieces { plcPcd.append(u32(UInt32(piece.cp))) }
        plcPcd.append(u32(UInt32(characters.count)))
        for piece in pieces {
            plcPcd.append(u16(0))
            plcPcd.append(u32(piece.compressed ? UInt32(piece.fc * 2) | 0x4000_0000 : UInt32(piece.fc)))
            plcPcd.append(u16(0))
        }
        var clx = Data([0x02])
        clx.append(u32(UInt32(plcPcd.count)))
        clx.append(plcPcd)
        place(33, clx)

        // Колонтитулы.
        var plcfHdd = Data()
        for bound in headerBounds { plcfHdd.append(u32(UInt32(bound))) }
        place(11, plcfHdd)

        // Сноски: список текстов и список ссылок на них в основном тексте.
        if !footnotes.isEmpty {
            var plcffndTxt = Data()
            for bound in footnoteBounds { plcffndTxt.append(u32(UInt32(bound))) }
            place(3, plcffndTxt)

            var plcffndRef = Data()
            for number in 0...footnotes.count { plcffndRef.append(u32(UInt32(number))) }
            for _ in footnotes { plcffndRef.append(u16(0)) }
            place(2, plcffndRef)
        }

        // Замечания: тексты, ссылки с номером автора и сами имена авторов.
        if !comments.isEmpty {
            var plcfandTxt = Data()
            for bound in commentBounds { plcfandTxt.append(u32(UInt32(bound))) }
            plcfandTxt.append(u32(UInt32(counts[4])))
            place(5, plcfandTxt)

            var plcfandRef = Data()
            for number in 0...comments.count { plcfandRef.append(u32(UInt32(number))) }
            for (number, _) in comments.enumerated() {
                var atrd = Data(count: 20)
                atrd.append(u16(UInt16(number)))
                atrd.append(u16(0))
                atrd.append(u16(0))
                atrd.append(u32(0))
                plcfandRef.append(atrd)
            }
            place(4, plcfandRef)

            var owners = Data()
            for comment in comments {
                let units = Array(comment.author.utf16)
                owners.append(u16(UInt16(units.count)))
                for unit in units { owners.append(u16(unit)) }
            }
            place(36, owners)
        }

        // MARK: Стили и свойства абзацев и знаков

        let bounds = paragraphBounds(characters: characters, mainCount: counts[0], pieces: pieces)
        if !styles.isEmpty {
            place(1, stylesheet())
        }
        if !styles.isEmpty || !paragraphStyles.isEmpty {
            let properties = paragraphProperties(documentSize: document.count, bounds: bounds)
            document.append(properties.pages)
            place(13, properties.plcfBtePapx)
        }
        if !deletedParagraphs.isEmpty || !hiddenParagraphs.isEmpty || !boldParagraphs.isEmpty {
            let properties = characterProperties(documentSize: document.count, bounds: bounds)
            document.append(properties.pages)
            place(12, properties.plcfBteChpx)
        }

        // MARK: Заголовок

        var fib = Data()
        fib.append(u16(0xA5EC))
        fib.append(u16(193))
        fib.append(u32(0))
        fib.append(u16(0))
        fib.append(u16(0x0200))          // fWhichTblStm: таблицы в `1Table`
        fib.append(Data(count: 32 - fib.count))
        fib.append(u16(14))              // csw
        fib.append(Data(count: 28))
        fib.append(u16(22))              // cslw
        fib.append(u32(UInt32(document.count)))
        fib.append(u32(0))
        fib.append(u32(0))
        for count in counts { fib.append(u32(UInt32(count))) }
        fib.append(Data(count: (22 - 11) * 4))
        fib.append(u16(93))              // cbRgFcLcb
        for index in 0..<93 {
            let location = locations[index]
            fib.append(u32(UInt32(location?.fc ?? 0)))
            fib.append(u32(UInt32(location?.lcb ?? 0)))
        }
        document.replaceSubrange(0..<fib.count, with: fib)

        return Self.container(streams: [
            (name: "WordDocument", data: document),
            (name: "1Table", data: table),
        ])
    }

    // MARK: - Стили и свойства абзацев

    /// Таблица стилей: заголовок, потом по записи на стиль.
    private func stylesheet() -> Data {
        var stshi = Data()
        stshi.append(u16(UInt16(styles.count + 1)))   // cstd, считая «Обычный»
        stshi.append(u16(10))                         // cbSTDBaseInFile
        stshi.append(u16(0))
        stshi.append(u16(UInt16(styles.count + 1)))
        stshi.append(u16(UInt16(styles.count + 1)))
        stshi.append(u16(0))

        var result = Data()
        result.append(u16(UInt16(stshi.count)))
        result.append(stshi)

        func style(_ name: String, sti: Int, outline: Int?) -> Data {
            var std = Data()
            std.append(u16(UInt16(sti & 0x0FFF)))
            std.append(u16(1))                        // stk: абзацный стиль
            std.append(u16(1))                        // cupx = 1
            std.append(u16(0))
            std.append(u16(0))
            let units = Array(name.utf16)
            std.append(u16(UInt16(units.count)))
            for unit in units { std.append(u16(unit)) }
            std.append(u16(0))                        // завершающий ноль
            var upx = Data()
            upx.append(u16(0))                        // istd внутри UPX
            if let outline {
                upx.append(u16(0x2640))
                upx.append(UInt8(outline))
            }
            std.append(u16(UInt16(upx.count)))
            std.append(upx)
            if std.count % 2 == 1 { std.append(0) }
            var entry = Data()
            entry.append(u16(UInt16(std.count)))
            entry.append(std)
            return entry
        }

        result.append(style("Обычный", sti: 0, outline: nil))
        for item in styles { result.append(style(item.name, sti: item.sti, outline: item.outlineLevel)) }
        return result
    }

    /// Границы абзацев основного текста: где абзац начинается в потоке
    /// и каким стилем набран.
    private func paragraphBounds(
        characters: [UInt16], mainCount: Int,
        pieces: [(cp: Int, fc: Int, compressed: Bool)]
    ) -> (list: [(fc: Int, istd: Int, number: Int)], end: Int) {
        /// Смещение знака в потоке — по тем же кускам, что и у читалки.
        func fileOffset(of cp: Int) -> Int {
            var piece = pieces[0]
            for candidate in pieces where candidate.cp <= cp { piece = candidate }
            let inside = cp - piece.cp
            return piece.fc + (piece.compressed ? inside : inside * 2)
        }

        var list: [(fc: Int, istd: Int, number: Int)] = []
        var start = 0
        var number = 0
        for (index, character) in characters.enumerated() where character == 0x0D {
            guard index < mainCount else { break }
            list.append((fc: fileOffset(of: start), istd: paragraphStyles[number] ?? 0, number: number))
            start = index + 1
            number += 1
        }
        return (list, fileOffset(of: min(mainCount, characters.count)))
    }

    /// Страница свойств: границы впереди, записи в конце, число записей
    /// последним байтом — так устроены все страницы свойств Word.
    ///
    /// `slot` — сколько байт на запись в середине страницы: у абзацев
    /// тринадцать, у знаков один.
    private func propertyPage(
        bounds: [Int], records: [Data], slot: Int, documentSize: Int
    ) -> (pages: Data, page: Int) {
        var page = Data()
        for bound in bounds { page.append(u32(UInt32(bound))) }

        let body = records.reduce(into: Data()) { $0.append($1) }
        var bodyStart = 511 - body.count
        bodyStart -= bodyStart % 2
        var cursor = bodyStart
        for record in records {
            page.append(UInt8(cursor / 2))
            page.append(Data(count: slot - 1))
            cursor += record.count
        }
        page.append(Data(count: max(0, bodyStart - page.count)))
        page.append(body)
        page.append(Data(count: max(0, 511 - page.count)))
        page.append(UInt8(records.count))

        // Страница кладётся на границу 512 байт — по номеру её и ищут.
        var pages = Data()
        let padding = (512 - documentSize % 512) % 512
        pages.append(Data(count: padding))
        pages.append(page)
        return (pages, (documentSize + padding) / 512)
    }

    /// Свойства абзацев: номер стиля у каждого.
    private func paragraphProperties(
        documentSize: Int, bounds: (list: [(fc: Int, istd: Int, number: Int)], end: Int)
    ) -> (pages: Data, plcfBtePapx: Data) {
        // Запись абзаца: «длина в парах байт, номер стиля, свойства».
        var records: [Data] = []
        for bound in bounds.list {
            var record = Data([2])
            record.append(u16(UInt16(bound.istd)))
            record.append(Data(count: 4 - record.count))
            records.append(record)
        }
        let page = propertyPage(
            bounds: bounds.list.map(\.fc) + [bounds.end],
            records: records, slot: 13, documentSize: documentSize
        )

        var plcfBtePapx = Data()
        plcfBtePapx.append(u32(UInt32(bounds.list.first?.fc ?? 0)))
        plcfBtePapx.append(u32(UInt32(bounds.end)))
        plcfBtePapx.append(u32(UInt32(page.page)))
        return (page.pages, plcfBtePapx)
    }

    /// Свойства знаков: правки, скрытый текст и начертание.
    ///
    /// Начертание пишется так же, как его пишет настоящий Word, — значением
    /// «наоборот, чем в стиле», а не «включено»: на этом разбор один раз
    /// уже споткнулся, и проверка нужна именно на этом виде записи.
    private func characterProperties(
        documentSize: Int, bounds: (list: [(fc: Int, istd: Int, number: Int)], end: Int)
    ) -> (pages: Data, plcfBteChpx: Data) {
        var records: [Data] = []
        for bound in bounds.list {
            var grpprl = Data()
            if deletedParagraphs.contains(bound.number) {
                grpprl.append(u16(0x0800))
                grpprl.append(1)
            }
            if hiddenParagraphs.contains(bound.number) {
                grpprl.append(u16(0x083C))
                grpprl.append(1)
            }
            if boldParagraphs.contains(bound.number) {
                grpprl.append(u16(0x0835))
                grpprl.append(129)
            }
            var record = Data([UInt8(grpprl.count)])
            record.append(grpprl)
            if record.count % 2 == 1 { record.append(0) }
            records.append(record)
        }
        let page = propertyPage(
            bounds: bounds.list.map(\.fc) + [bounds.end],
            records: records, slot: 1, documentSize: documentSize
        )

        var plcfBteChpx = Data()
        plcfBteChpx.append(u32(UInt32(bounds.list.first?.fc ?? 0)))
        plcfBteChpx.append(u32(UInt32(bounds.end)))
        plcfBteChpx.append(u32(UInt32(page.page)))
        return (page.pages, plcfBteChpx)
    }

    // MARK: - Контейнер OLE2

    /// Составной документ из готовых потоков.
    static func container(streams: [(name: String, data: Data)]) -> Data {
        let sectorSize = 512
        let miniSectorSize = 64
        let miniCutoff = 4096
        let endOfChain: UInt32 = 0xFFFF_FFFE
        let free: UInt32 = 0xFFFF_FFFF
        let fatSector: UInt32 = 0xFFFF_FFFD

        var sectors: [Data] = []
        var chain: [UInt32] = []

        func allocate(_ data: Data) -> UInt32 {
            guard !data.isEmpty else { return endOfChain }
            var padded = data
            let padding = (sectorSize - padded.count % sectorSize) % sectorSize
            padded.append(Data(count: padding))
            let first = UInt32(sectors.count)
            let count = padded.count / sectorSize
            for index in 0..<count {
                sectors.append(padded[(index * sectorSize)..<((index + 1) * sectorSize)])
                chain.append(index == count - 1 ? endOfChain : UInt32(sectors.count))
            }
            return first
        }

        // Мелкие потоки живут в мини-потоке, крупные — в секторах файла.
        var miniStream = Data()
        var miniFAT: [UInt32] = []
        var starts: [String: UInt32] = [:]
        for stream in streams where !stream.data.isEmpty && stream.data.count < miniCutoff {
            let first = UInt32(miniStream.count / miniSectorSize)
            var padded = stream.data
            padded.append(Data(count: (miniSectorSize - padded.count % miniSectorSize) % miniSectorSize))
            let count = padded.count / miniSectorSize
            for index in 0..<count {
                miniFAT.append(index == count - 1 ? endOfChain : first + UInt32(index) + 1)
            }
            miniStream.append(padded)
            starts[stream.name] = first
        }
        for stream in streams where stream.data.count >= miniCutoff {
            starts[stream.name] = allocate(stream.data)
        }

        let miniStreamStart = allocate(miniStream)
        var miniFATBytes = Data()
        for entry in miniFAT { miniFATBytes.append(u32s(entry)) }
        let miniFATStart = allocate(miniFATBytes)
        let miniFATSectors = miniFATBytes.isEmpty ? 0 : (miniFATBytes.count + sectorSize - 1) / sectorSize

        // Каталог: корень, потом по записи на поток.
        func entry(name: String, type: UInt8, start: UInt32, size: Int) -> Data {
            var record = Data(count: 128)
            let units = Array(name.utf16)
            for (index, unit) in units.enumerated() where index < 31 {
                record[index * 2] = UInt8(unit & 0xFF)
                record[index * 2 + 1] = UInt8(unit >> 8)
            }
            let length = UInt16((units.count + 1) * 2)
            record[64] = UInt8(length & 0xFF)
            record[65] = UInt8(length >> 8)
            record[66] = type
            record[67] = 1
            for offset in [68, 72, 76] {
                for byte in 0..<4 { record[offset + byte] = 0xFF }
            }
            let startBytes = u32s(start)
            for byte in 0..<4 { record[116 + byte] = startBytes[startBytes.startIndex + byte] }
            let sizeBytes = u32s(UInt32(size))
            for byte in 0..<4 { record[120 + byte] = sizeBytes[sizeBytes.startIndex + byte] }
            return record
        }

        var directory = entry(name: "Root Entry", type: 5, start: miniStreamStart, size: miniStream.count)
        for stream in streams {
            directory.append(entry(
                name: stream.name, type: 2, start: starts[stream.name] ?? endOfChain, size: stream.data.count
            ))
        }
        let directoryStart = allocate(directory)

        // Сектора самой таблицы размещения: их номера тоже в ней перечислены.
        let perSector = sectorSize / 4
        var fatSectorCount = 1
        while (sectors.count + fatSectorCount + perSector - 1) / perSector > fatSectorCount {
            fatSectorCount += 1
        }
        let dataSectors = sectors.count
        var fat = chain
        for _ in 0..<fatSectorCount {
            fat.append(fatSector)
        }
        while fat.count < fatSectorCount * perSector { fat.append(free) }

        var header = Data(count: 512)
        let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        for (index, byte) in signature.enumerated() { header[index] = byte }
        func write(_ value: UInt32, at offset: Int, into data: inout Data) {
            let bytes = u32s(value)
            for byte in 0..<4 { data[offset + byte] = bytes[bytes.startIndex + byte] }
        }
        func write16(_ value: UInt16, at offset: Int, into data: inout Data) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8(value >> 8)
        }
        write16(0x003E, at: 24, into: &header)
        write16(3, at: 26, into: &header)
        write16(0xFFFE, at: 28, into: &header)
        write16(9, at: 30, into: &header)
        write16(6, at: 32, into: &header)
        write(UInt32(fatSectorCount), at: 44, into: &header)
        write(directoryStart, at: 48, into: &header)
        write(UInt32(miniCutoff), at: 56, into: &header)
        write(miniFATStart, at: 60, into: &header)
        write(UInt32(miniFATSectors), at: 64, into: &header)
        write(endOfChain, at: 68, into: &header)
        write(0, at: 72, into: &header)
        for index in 0..<109 {
            write(index < fatSectorCount ? UInt32(dataSectors + index) : free, at: 76 + index * 4, into: &header)
        }

        var result = header
        for sector in sectors { result.append(sector) }
        for index in 0..<fatSectorCount {
            for slot in 0..<perSector { result.append(u32s(fat[index * perSector + slot])) }
        }
        return result
    }

    // MARK: - Числа

    private func u16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private func u32(_ value: UInt32) -> Data { DocFixture.u32s(value) }

    fileprivate static func u32s(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}

private func u32s(_ value: UInt32) -> Data { DocFixture.u32s(value) }
