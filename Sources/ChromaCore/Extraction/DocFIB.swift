import Foundation

/// Заголовок двоичного `.doc` — File Information Block.
///
/// Первое, что лежит в потоке `WordDocument`: подпись, версия, флаги и две
/// таблицы — длины подпотоков (`ccp*`) и адреса всего остального (`fc`/`lcb`).
/// Разобрать её дёшево, а отвечает она на вопрос, на который у `.doc` до сих
/// пор ответа не было: **есть ли в этом файле комментарии, сноски
/// и колонтитулы, и сколько там знаков**.
///
/// Проверено на файлах заказчика: в приказе с правками — 660 знаков
/// комментариев и 51 знак колонтитула, о которых приложение молчало.
struct DocFIB {
    /// Длины подпотоков в знаках. Идут в тексте подряд и ровно в этом порядке.
    var characters: [Subdocument: Int] = [:]
    /// Адреса и длины таблиц: `fibRgFcLcb`, по индексу.
    var pairs: [(fc: Int, lcb: Int)] = []
    /// Имя потока с таблицами: `1Table` или `0Table`.
    var tableStreamName: String = "1Table"
    /// Текст собран из кусков, а не лежит одним куском. На разбор не влияет —
    /// таблица кусков читается в обоих случаях, — но объясняет, почему её нет.
    var isComplex = false
    /// Файл зашифрован: дальше идти некуда, и делать вид, что прочитали, нельзя.
    var isEncrypted = false
    /// Версия Word, записавшего файл. 193 и выше — Word 97 и новее.
    var version = 0

    /// Части документа, лежащие в одном текстовом потоке одна за другой.
    enum Subdocument: Int, CaseIterable {
        case main, footnotes, headers, macros, annotations, endnotes, textboxes, headerTextboxes
    }

    /// Индексы в `fibRgFcLcb`, которые нужны разбору. Имена — как в MS-DOC.
    enum Table: Int {
        case stshf = 1
        case plcffndRef = 2
        case plcffndTxt = 3
        case plcfandRef = 4
        case plcfandTxt = 5
        case plcfHdd = 11
        case plcfBteChpx = 12
        case plcfBtePapx = 13
        case clx = 33
        case grpXstAtnOwners = 36
    }

    /// `nil` — это не заголовок Word 97, и своей читалке здесь делать нечего.
    init?(stream: Data) {
        guard CFBContainerReader.u16(stream, 0) == 0xA5EC else { return nil }
        version = Int(CFBContainerReader.u16(stream, 2))
        // Word 6 и 7 (nFib 101 и 104) писали заголовок другой длины: у него нет
        // ни csw, ни cslw, и разбирать его этим кодом — читать мусор. Такие
        // файлы уходят системному импортёру, как и раньше.
        guard version >= 193 else { return nil }

        let flags = CFBContainerReader.u16(stream, 10)
        isComplex = flags & 0x0004 != 0
        isEncrypted = flags & 0x0100 != 0
        tableStreamName = flags & 0x0200 != 0 ? "1Table" : "0Table"

        // Дальше заголовок переменной длины: три блока, каждый со своим
        // счётчиком впереди. Читать по постоянным смещениям нельзя — они
        // разъезжаются от версии к версии, и это первый способ прочитать мусор.
        let csw = Int(CFBContainerReader.u16(stream, 32))
        let cslwOffset = 34 + csw * 2
        let cslw = Int(CFBContainerReader.u16(stream, cslwOffset))
        let rgLwOffset = cslwOffset + 2
        guard cslw >= 22, rgLwOffset + cslw * 4 <= stream.count else { return nil }

        // ccpText … ccpHdrTxbx — со второго слова после трёх служебных.
        for (index, part) in Subdocument.allCases.enumerated() {
            let value = Int(Int32(bitPattern: CFBContainerReader.u32(stream, rgLwOffset + 12 + index * 4)))
            characters[part] = max(0, value)
        }

        let cbRgFcLcbOffset = rgLwOffset + cslw * 4
        let cbRgFcLcb = Int(CFBContainerReader.u16(stream, cbRgFcLcbOffset))
        let blob = cbRgFcLcbOffset + 2
        guard cbRgFcLcb > 0, blob + cbRgFcLcb * 8 <= stream.count else { return nil }
        pairs.reserveCapacity(cbRgFcLcb)
        for index in 0..<cbRgFcLcb {
            pairs.append((
                fc: Int(CFBContainerReader.u32(stream, blob + index * 8)),
                lcb: Int(CFBContainerReader.u32(stream, blob + index * 8 + 4))
            ))
        }
    }

    /// Адрес таблицы в потоке таблиц, если она в файле есть.
    func location(of table: Table) -> (fc: Int, lcb: Int)? {
        guard table.rawValue < pairs.count else { return nil }
        let pair = pairs[table.rawValue]
        guard pair.lcb > 0 else { return nil }
        return pair
    }

    func count(of part: Subdocument) -> Int { characters[part] ?? 0 }

    /// Где подпоток начинается в общей нумерации знаков.
    func start(of part: Subdocument) -> Int {
        Subdocument.allCases.prefix(part.rawValue).reduce(0) { $0 + count(of: $1) }
    }

    /// Всего знаков во всех подпотоках.
    var totalCharacters: Int {
        Subdocument.allCases.reduce(0) { $0 + count(of: $1) }
    }
}
