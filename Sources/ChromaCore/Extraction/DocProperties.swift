import Foundation

/// Свойства знаков и абзацев двоичного `.doc`.
///
/// В `.docx` это соседние теги внутри абзаца; здесь — отдельные страницы
/// ровно по 512 байт в потоке документа, на которые указывает список
/// «кусок текста → номер страницы». Внутри страницы свойства лежат наборами
/// (`grpprl`), а каждое свойство — двухбайтовым кодом, в котором зашита
/// и длина значения. Читать их надо потому, что без них:
///
/// - удалённый правкой текст попадёт в базу вместе с итоговой редакцией;
/// - скрытый текст, которого нет ни на экране, ни в печати, попадёт тоже;
/// - таблица развалится: метка конца строки и метка конца ячейки — один
///   и тот же знак, и отличить их можно только свойством абзаца.
extension DocPartsReader {
    /// Свойства куска текста: то, что Word держит не в тексте, а рядом.
    struct CharacterRun {
        var start = 0
        var end = 0
        /// Удалено правкой. Сам текст остаётся в файле, и без этого признака
        /// в базу попали бы обе редакции сразу — и старая, и новая.
        var isDeleted = false
        /// Правкой добавлено: на текст не влияет (он и есть итоговая
        /// редакция), но говорит, что в документе идёт рецензирование.
        var isInserted = false
        /// Скрытый текст: Word его не показывает и не печатает.
        var isHidden = false
        /// `nil` — про начертание прогон ничего не говорит, и оно приходит
        /// из стиля абзаца. В `.doc` это обычное дело, а не редкость.
        var isBold: Bool?
        /// Начертание задано **относительно стиля**: «не так, как в стиле».
        /// Именно так Word пишет полужирный в документе, чей стиль обычный, —
        /// на проверенном приказе таких прогонов 64 из 64, и без этого разбора
        /// документ выглядел бы набранным без единого выделения.
        var invertsBold = false
        /// Кегль в полуточках, как его пишет Word. `nil` — тоже из стиля.
        var halfPoints: Int?
    }

    /// Свойства абзаца: где он стоит и чем набран.
    struct ParagraphRun {
        var start = 0
        var end = 0
        /// Номер стиля абзаца в таблице стилей.
        var istd = 0
        var isInTable = false
        /// Знак конца строки таблицы — сам по себе текста не несёт.
        var isRowEnd = false
        /// Уровень структуры, заданный прямо в абзаце.
        var outline: Int?
        /// Экземпляр списка, заданный прямо в абзаце (`sprmPIlfo`), с 1;
        /// 0 — абзац из списка выведен, даже если его стиль нумерован.
        var listInstance: Int?
        /// Уровень в списке (`sprmPIlvl`), с 0.
        var listLevel: Int?
        /// Ячейки строки — только у знака конца строки: там Word хранит
        /// описание всей строки таблицы.
        var rowCells: [TableCellDefinition]?
    }

    /// Ячейка строки таблицы: где стоит и объединена ли.
    ///
    /// Границы — в двадцатых долях пункта, от края страницы. Сетки колонок,
    /// как у `.docx`, в двоичном формате нет: у каждой строки свои границы,
    /// и общая сетка таблицы собирается из них потом.
    struct TableCellDefinition: Equatable {
        var left: Int
        var right: Int
        /// Продолжение объединения вниз: значения своего нет.
        var continuesAbove = false
    }

    /// Коды свойств, которые разбираются. Имена — как в MS-DOC.
    enum Sprm: UInt16 {
        case characterDeleted = 0x0800
        case characterInserted = 0x0801
        case characterBold = 0x0835
        case characterHidden = 0x083C
        case characterSize = 0x4A43
        case paragraphInTable = 0x2416
        case paragraphRowEnd = 0x2417
        case paragraphOutline = 0x2640
        case paragraphStyle = 0x4600
        /// Уровень в списке (`sprmPIlvl`).
        case paragraphListLevel = 0x260A
        /// Экземпляр списка (`sprmPIlfo`).
        case paragraphListInstance = 0x460B
        /// Описание строки таблицы (`sprmTDefTable`).
        case tableDefinition = 0xD608
        /// Правка объединения вниз одной ячейки (`sprmTVertMerge`).
        case tableVerticalMerge = 0xD62B
    }

    // MARK: - Страницы свойств

    /// Страница по её номеру: свойства лежат не в таблице, а в самом потоке
    /// документа, страницами ровно по 512 байт.
    private func page(_ number: Int) -> Data? {
        let start = number * 512
        guard number >= 0, start >= 0, start + 512 <= document.count else { return nil }
        return document[(document.startIndex + start)..<(document.startIndex + start + 512)]
    }

    /// Номера страниц свойств из списка «кусок текста → страница».
    private func propertyPages(_ location: DocFIB.Table) -> [Int] {
        guard let pair = fib.location(of: location) else { return [] }
        let count = Self.plcCount(lcb: pair.lcb, cbData: 4)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let record = Self.plcRecord(table, at: pair.fc, lcb: pair.lcb, cbData: 4, index: index)
            return Int(CFBContainerReader.u32(record, 0) & 0x003F_FFFF)
        }
    }

    /// Свойства знаков — по возрастанию смещения.
    func characterRuns() -> [CharacterRun] {
        var result: [CharacterRun] = []
        for number in propertyPages(.plcfBteChpx) {
            guard let page = page(number) else { continue }
            let count = Int(CFBContainerReader.byte(page, 511))
            guard count > 0, 4 * (count + 1) + count <= 511 else { continue }
            for index in 0..<count {
                var run = CharacterRun(
                    start: Int(CFBContainerReader.u32(page, index * 4)),
                    end: Int(CFBContainerReader.u32(page, (index + 1) * 4))
                )
                guard run.end > run.start else { continue }
                let word = Int(CFBContainerReader.byte(page, 4 * (count + 1) + index))
                if word > 0 {
                    let offset = word * 2
                    let size = Int(CFBContainerReader.byte(page, offset))
                    if size > 0, offset + 1 + size <= 511 {
                        Self.forEachSprm(page[(page.startIndex + offset + 1)..<(page.startIndex + offset + 1 + size)]) { code, value in
                            // Признак «включено» Word пишет четырьмя способами:
                            // 0 — выключено, 1 — включено, 128 — как в стиле,
                            // 129 — наоборот, чем в стиле.
                            let flag = CFBContainerReader.byte(value, 0)
                            switch Sprm(rawValue: code) {
                            case .characterDeleted: run.isDeleted = flag == 1 || flag == 129
                            case .characterInserted: run.isInserted = flag == 1 || flag == 129
                            case .characterHidden: run.isHidden = flag == 1 || flag == 129
                            case .characterBold:
                                run.invertsBold = flag == 129
                                run.isBold = flag <= 1 ? flag == 1 : nil
                            case .characterSize: run.halfPoints = Int(CFBContainerReader.u16(value, 0))
                            default: break
                            }
                        }
                    }
                }
                result.append(run)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Свойства абзацев — по возрастанию смещения.
    func paragraphRuns() -> [ParagraphRun] {
        var result: [ParagraphRun] = []
        for number in propertyPages(.plcfBtePapx) {
            guard let page = page(number) else { continue }
            let count = Int(CFBContainerReader.byte(page, 511))
            guard count > 0, 4 * (count + 1) + count * 13 <= 511 else { continue }
            for index in 0..<count {
                var run = ParagraphRun(
                    start: Int(CFBContainerReader.u32(page, index * 4)),
                    end: Int(CFBContainerReader.u32(page, (index + 1) * 4))
                )
                guard run.end > run.start else { continue }
                // На абзац приходится тринадцать байт, и значащий из них
                // первый: половина смещения записи со свойствами.
                let word = Int(CFBContainerReader.byte(page, 4 * (count + 1) + index * 13))
                guard word > 0 else { result.append(run); continue }
                let offset = word * 2
                // Длина записи задана в парах байт; ноль означает, что длина
                // не поместилась в байт и лежит в следующем.
                var size = Int(CFBContainerReader.byte(page, offset)) * 2 - 1
                var body = offset + 1
                if size < 0 {
                    size = Int(CFBContainerReader.byte(page, offset + 1)) * 2
                    body = offset + 2
                }
                guard size >= 2, body + size <= 511 else { result.append(run); continue }
                run.istd = Int(CFBContainerReader.u16(page, body))
                Self.forEachSprm(page[(page.startIndex + body + 2)..<(page.startIndex + body + size)]) { code, value in
                    switch Sprm(rawValue: code) {
                    case .paragraphInTable: run.isInTable = CFBContainerReader.byte(value, 0) == 1
                    case .paragraphRowEnd: run.isRowEnd = CFBContainerReader.byte(value, 0) == 1
                    case .paragraphStyle: run.istd = Int(CFBContainerReader.u16(value, 0))
                    case .paragraphOutline:
                        let level = Int(CFBContainerReader.byte(value, 0))
                        run.outline = level <= 8 ? level : nil
                    case .paragraphListInstance:
                        run.listInstance = Self.listInstance(value)
                    case .paragraphListLevel:
                        let level = Int(CFBContainerReader.byte(value, 0))
                        run.listLevel = level <= 8 ? level : nil
                    case .tableDefinition:
                        run.rowCells = Self.tableCells(value)
                    case .tableVerticalMerge:
                        // cb, номер ячейки, признак — по байту.
                        guard value.count >= 3, var cells = run.rowCells else { break }
                        let index = Int(CFBContainerReader.byte(value, 1))
                        let flag = CFBContainerReader.byte(value, 2)
                        if index < cells.count { cells[index].continuesAbove = flag == 1 }
                        run.rowCells = cells
                    default: break
                    }
                }
                result.append(run)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Номер экземпляра списка из `sprmPIlfo`: со знаком, и всё, что не
    /// номер экземпляра (0 и особое 0xF801 — «без нумерации»), — 0.
    static func listInstance(_ value: Data) -> Int {
        let raw = Int(Int16(bitPattern: CFBContainerReader.u16(value, 0)))
        return (1...0x07FE).contains(raw) ? raw : 0
    }

    /// Ячейки из `sprmTDefTable`: число ячеек, их границы и по двадцать
    /// байт описания на ячейку (MS-DOC, TDefTableOperand и TC80).
    ///
    /// Из описания берётся одно — признак объединения вниз (биты 5–6
    /// первого слова): 1 — продолжение, 3 — начало. Описаний может быть
    /// меньше, чем ячеек: у недостающих объединения нет.
    static func tableCells(_ value: Data) -> [TableCellDefinition]? {
        // Первые два байта — длина операнда, их уже учёл обход.
        guard value.count >= 3 else { return nil }
        let count = Int(CFBContainerReader.byte(value, 2))
        let edges = 3
        guard count > 0, edges + (count + 1) * 2 <= value.count else { return nil }
        var result: [TableCellDefinition] = []
        for index in 0..<count {
            let left = Int(Int16(bitPattern: CFBContainerReader.u16(value, edges + index * 2)))
            let right = Int(Int16(bitPattern: CFBContainerReader.u16(value, edges + (index + 1) * 2)))
            result.append(TableCellDefinition(left: left, right: max(left, right)))
        }
        let descriptions = edges + (count + 1) * 2
        for index in 0..<count {
            let offset = descriptions + index * 20
            guard offset + 2 <= value.count else { break }
            let flags = CFBContainerReader.u16(value, offset)
            result[index].continuesAbove = (flags >> 5) & 0x3 == 1
        }
        return result
    }

    // MARK: - Обход набора свойств

    /// Свойства набора по одному: код и его значение.
    ///
    /// Длина значения зашита в самом коде — тремя битами, и это единственный
    /// способ пройти набор насквозь: пропустить незнакомое свойство можно,
    /// только зная, сколько оно занимает.
    static func forEachSprm(_ grpprl: Data, _ visit: (UInt16, Data) -> Void) {
        var offset = 0
        while offset + 2 <= grpprl.count {
            let code = CFBContainerReader.u16(grpprl, offset)
            guard code != 0 else { return }
            let value = offset + 2
            let length: Int
            switch (code >> 13) & 0x7 {
            case 0, 1: length = 1
            case 2, 4, 5: length = 2
            case 3: length = 4
            case 7: length = 3
            default:
                // Переменная длина: сколько дальше, сказано первым байтом
                // значения. Исключение одно — описание таблицы, у него
                // на длину отведено два байта.
                length = code == 0xD608
                    ? 2 + Int(CFBContainerReader.u16(grpprl, value))
                    : 1 + Int(CFBContainerReader.byte(grpprl, value))
            }
            guard length > 0, value + length <= grpprl.count else { return }
            visit(code, grpprl[(grpprl.startIndex + value)..<(grpprl.startIndex + value + length)])
            offset = value + length
        }
    }

    /// Свойства знака по его смещению в потоке.
    static func run<Element>(
        at offset: Int, in runs: [Element], start: (Element) -> Int, end: (Element) -> Int
    ) -> Element? {
        var low = 0
        var high = runs.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if offset < start(runs[middle]) {
                high = middle - 1
            } else if offset >= end(runs[middle]) {
                low = middle + 1
            } else {
                return runs[middle]
            }
        }
        return nil
    }
}
