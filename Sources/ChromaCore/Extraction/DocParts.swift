import Foundation

/// Разбор двоичного `.doc` — того самого формата Word 97–2003.
///
/// В отличие от `.docx`, здесь нет ни XML, ни частей контейнера: `.doc` — это
/// OLE2-контейнер с несколькими потоками байт. Текст в нём не лежит одним
/// куском, а собирается по **таблице кусков**: «взять столько-то знаков
/// с такого-то смещения, в такой-то кодировке». Поэтому у `.doc` до сих пор
/// нельзя было даже спросить, есть ли внутри комментарии, — а они там есть:
/// на файлах заказчика замерено 660 знаков замечаний в одном приказе,
/// о которых приложение молчало.
///
/// Разбор идёт ступенями, и каждая отвечает за своё:
/// 1. заголовок FIB → сколько знаков в каждом подпотоке (`DocFIB`);
/// 2. таблица кусков → сам текст, включая колонтитулы, сноски и замечания;
/// 3. таблица стилей → уровни заголовков из разметки автора.
public struct DocPartsReader {
    /// Что в файле есть, по заголовку — до того, как разобран хоть один знак.
    public struct Inventory: Hashable, Sendable {
        /// Сколько замечаний рецензентов и сколько в них знаков.
        public var comments = 0
        public var commentCharacters = 0
        public var footnotes = 0
        public var footnoteCharacters = 0
        /// Колонтитулы — без служебных разделителей сносок, которые Word
        /// держит в том же подпотоке и которые текстом не являются.
        public var headerCharacters = 0
        public var endnoteCharacters = 0
        /// Надписи и врезки: полноценный текст, который системный импортёр
        /// не отдаёт вовсе.
        public var textboxCharacters = 0
        public var mainCharacters = 0

        public var isEmpty: Bool {
            comments == 0 && footnotes == 0 && headerCharacters == 0
                && endnoteCharacters == 0 && textboxCharacters == 0
        }
    }

    let fib: DocFIB
    /// Поток `WordDocument`: заголовок, текст и страницы свойств.
    let document: Data
    /// Поток `1Table` или `0Table`: все таблицы диапазонов.
    let table: Data

    /// `nil` — файл не двоичный `.doc`, зашифрован или записан Word 6/7.
    /// Во всех трёх случаях дальше идёт системный импортёр, как и раньше.
    public init?(url: URL) {
        guard let reader = try? CFBContainerReader(url: url),
              let document = try? reader.read("WordDocument"),
              let fib = DocFIB(stream: document), !fib.isEncrypted
        else { return nil }
        self.fib = fib
        self.document = document
        self.table = (try? reader.read(fib.tableStreamName)) ?? Data()
    }

    /// Ступень 1: что лежит в файле, по одному заголовку.
    ///
    /// Стоит это чтения полутора килобайт и не зависит от того, удастся ли
    /// собрать текст: даже если разбор кусков споткнётся, сказать «в файле
    /// 660 знаков замечаний» уже можно.
    public func inventory() -> Inventory {
        var result = Inventory()
        result.mainCharacters = fib.count(of: .main)
        result.commentCharacters = fib.count(of: .annotations)
        result.footnoteCharacters = fib.count(of: .footnotes)
        result.endnoteCharacters = fib.count(of: .endnotes)
        result.textboxCharacters = fib.count(of: .textboxes) + fib.count(of: .headerTextboxes)

        // Замечания и сноски считаются по таблицам ссылок: длина в знаках
        // не говорит, одно это замечание на десять строк или десять коротких.
        if let location = fib.location(of: .plcfandRef) {
            result.comments = Self.plcCount(lcb: location.lcb, cbData: 30)
        }
        if let location = fib.location(of: .plcffndRef) {
            result.footnotes = Self.plcCount(lcb: location.lcb, cbData: 2)
        }
        result.headerCharacters = headerStories().reduce(0) { $0 + ($1.end - $1.start) }
        return result
    }

    /// Границы настоящих колонтитулов внутри их подпотока.
    ///
    /// Word держит в этом же подпотоке шесть служебных историй — разделители
    /// сносок и концевых сносок, — и они идут **первыми**. Считать их
    /// колонтитулом значит обещать человеку текст, которого он в документе
    /// не увидит; поэтому первые шесть пропускаются, а дальше на каждый раздел
    /// приходится ровно шесть историй: два верхних колонтитула, два нижних
    /// и по одному на первую страницу.
    func headerStories() -> [(start: Int, end: Int, isFooter: Bool)] {
        guard let location = fib.location(of: .plcfHdd) else { return [] }
        let cps = Self.plcCPs(table, at: location.fc, lcb: location.lcb, cbData: 0)
        guard cps.count > 7 else { return [] }
        var result: [(start: Int, end: Int, isFooter: Bool)] = []
        for index in 6..<(cps.count - 1) {
            let start = cps[index]
            let end = cps[index + 1]
            // История из одного знака — пустая: там только знак конца абзаца.
            guard end - start > 1 else { continue }
            let position = (index - 6) % 6
            result.append((start, end, isFooter: position == 2 || position == 3 || position == 5))
        }
        return result
    }

    // MARK: - Plc: список позиций и одинаковых записей при них

    /// Сколько записей в списке такой длины.
    static func plcCount(lcb: Int, cbData: Int) -> Int {
        guard lcb > 4, cbData >= 0 else { return 0 }
        return max(0, (lcb - 4) / (4 + cbData))
    }

    /// Позиции в знаках: их всегда на одну больше, чем записей.
    static func plcCPs(_ data: Data, at fc: Int, lcb: Int, cbData: Int) -> [Int] {
        let count = plcCount(lcb: lcb, cbData: cbData)
        guard count > 0, fc >= 0, fc + lcb <= data.count else { return [] }
        return (0...count).map { Int(Int32(bitPattern: CFBContainerReader.u32(data, fc + $0 * 4))) }
    }

    /// Запись номер `index` — те `cbData` байт, что идут после всех позиций.
    static func plcRecord(_ data: Data, at fc: Int, lcb: Int, cbData: Int, index: Int) -> Data {
        let count = plcCount(lcb: lcb, cbData: cbData)
        guard cbData > 0, index >= 0, index < count else { return Data() }
        let start = fc + (count + 1) * 4 + index * cbData
        guard start >= 0, start + cbData <= data.count else { return Data() }
        return data[(data.startIndex + start)..<(data.startIndex + start + cbData)]
    }
}

// MARK: - Ступень 2: текст по таблице кусков

extension DocPartsReader {
    /// Кусок текста: с какого знака он начинается, по какому смещению лежит
    /// и в какой кодировке записан.
    ///
    /// Однобайтовым куском Word пишет только то, что укладывается в первую
    /// половину таблицы символов, — кириллица всегда идёт двухбайтовой.
    struct Piece: Hashable {
        let cp: Int
        let fc: Int
        let isCompressed: Bool
    }

    /// Знаки всех подпотоков подряд — и смещение каждого в потоке документа.
    ///
    /// Смещение хранится рядом с каждым знаком не для красоты: свойства знака
    /// и абзаца заданы диапазонами **байт в потоке**, а не номерами знаков,
    /// и без этой пары найти их нельзя.
    struct Characters {
        var units: [UInt16] = []
        var offsets: [Int] = []
    }

    /// Предел: больше — это уже не документ, а выгрузка, и держать под неё
    /// два массива по знаку незачем. Такой файл уходит системному импортёру.
    static let maxCharacters = 8_000_000

    /// Таблица кусков из потока таблиц.
    func pieces() -> [Piece] {
        guard let location = fib.location(of: .clx), location.fc >= 0,
              location.fc + location.lcb <= table.count else { return [] }
        var offset = location.fc
        let end = location.fc + location.lcb
        var list: (fc: Int, lcb: Int)?
        while offset < end {
            switch CFBContainerReader.byte(table, offset) {
            case 0x01:
                // Свойства кусков — разбору текста они не нужны, но пропустить
                // их надо ровно на их длину, иначе дальше идёт мусор.
                offset += 3 + Int(CFBContainerReader.u16(table, offset + 1))
            case 0x02:
                list = (fc: offset + 5, lcb: Int(CFBContainerReader.u32(table, offset + 1)))
                offset = end
            default:
                offset = end
            }
        }
        guard let list, list.lcb > 4, list.fc >= 0, list.fc + list.lcb <= table.count else { return [] }
        let count = Self.plcCount(lcb: list.lcb, cbData: 8)
        var result: [Piece] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let cp = Int(Int32(bitPattern: CFBContainerReader.u32(table, list.fc + index * 4)))
            let record = list.fc + (count + 1) * 4 + index * 8
            let raw = CFBContainerReader.u32(table, record + 2)
            let compressed = raw & 0x4000_0000 != 0
            let fc = Int(raw & 0x3FFF_FFFF)
            guard cp >= 0, fc >= 0 else { return [] }
            result.append(Piece(cp: cp, fc: compressed ? fc / 2 : fc, isCompressed: compressed))
        }
        return result.sorted { $0.cp < $1.cp }
    }

    /// Собранный текст. `nil` — таблицы кусков нет или она врёт про размеры,
    /// и тогда честнее отдать файл системному импортёру, чем выдать обрывки.
    func characters() -> Characters? {
        let pieces = pieces()
        let total = fib.totalCharacters
        guard !pieces.isEmpty, total > 0, total <= Self.maxCharacters else { return nil }

        var result = Characters()
        result.units.reserveCapacity(total)
        result.offsets.reserveCapacity(total)
        for (index, piece) in pieces.enumerated() {
            let next = index + 1 < pieces.count ? pieces[index + 1].cp : total
            guard next > piece.cp else { continue }
            for position in 0..<(next - piece.cp) {
                let offset = piece.fc + (piece.isCompressed ? position : position * 2)
                guard offset >= 0, offset + (piece.isCompressed ? 0 : 1) < document.count else { return nil }
                result.units.append(piece.isCompressed
                    ? Self.ansi(CFBContainerReader.byte(document, offset))
                    : CFBContainerReader.u16(document, offset))
                result.offsets.append(offset)
            }
        }
        return result.units.isEmpty ? nil : result
    }

    /// Однобайтовый знак в юникодный. Обычная латиница совпадает сама с собой,
    /// а два десятка значений в середине таблицы — нет: там лежат типографские
    /// кавычки, тире и многоточие, и без этой таблицы они станут кракозябрами.
    static func ansi(_ byte: UInt8) -> UInt16 {
        let special: [UInt8: UInt16] = [
            0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
            0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
            0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
            0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
            0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
            0x9E: 0x017E, 0x9F: 0x0178,
        ]
        return special[byte] ?? UInt16(byte)
    }
}
