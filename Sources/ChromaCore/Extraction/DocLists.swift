import Foundation

/// Нумерация списков двоичного `.doc`.
///
/// **Зачем.** Номер пункта в `.doc`, как и в `.docx`, — не текст, а свойство
/// абзаца: Word рисует «3.2.1.» по определению списка, в потоке знаков его
/// нет. Без этого разбора договор приходил в базу без единого номера пункта,
/// и вопрос «что сказано в пункте 5.3» не находил ничего: ни заголовка
/// раздела, ни ссылок на него из текста, — числа есть только в разметке.
///
/// **Как устроено (MS-DOC 2.9.147, 2.9.150, 2.9.131).** В потоке таблиц —
/// два списка:
/// - `PlfLst` — определения: `LSTF` по 28 байт (идентификатор, стили
///   уровней, признак одноуровневого), а **сразу за таблицей** — уровни
///   `LVL` всех определений подряд: по одному у одноуровневого, по девять
///   у прочих. Длина `lcbPlfLst` уровней не включает;
/// - `PlfLfo` — экземпляры: `LFO` по 16 байт (чьё определение и сколько
///   уровней переопределено), за ними у каждого экземпляра — `LFOData`:
///   4 байта `cp` и переопределения уровней (`LFOLVL`, 8 байт, и `LVL`,
///   если переопределён вид).
///
/// Абзац ссылается на экземпляр (`sprmPIlfo`, с 1) и уровень (`sprmPIlvl`).
/// Модель та же, что у `.docx`: определение — `abstractNum`, экземпляр —
/// `num`, — поэтому таблица собирается в `DocxPartsReader.NumberingTable`
/// и считается тем же счётчиком: один документ, сохранённый в двух
/// форматах, получает одни и те же номера.
extension DocPartsReader {
    func numberingTable() -> DocxPartsReader.NumberingTable {
        var result = DocxPartsReader.NumberingTable()
        guard let lists = fib.location(of: .plfLst), lists.fc >= 0, lists.fc + 2 <= table.count else { return result }

        // MARK: Определения

        let count = Int(Int16(bitPattern: CFBContainerReader.u16(table, lists.fc)))
        guard count > 0, lists.fc + 2 + count * 28 <= table.count else { return result }
        var definitions: [(id: String, simple: Bool, styles: [Int])] = []
        for index in 0..<count {
            let offset = lists.fc + 2 + index * 28
            let id = String(CFBContainerReader.u32(table, offset))
            let styles = (0..<9).map { Int(CFBContainerReader.u16(table, offset + 8 + $0 * 2)) }
            let simple = CFBContainerReader.byte(table, offset + 26) & 0x01 == 1
            definitions.append((id, simple, styles))
        }
        var offset = lists.fc + 2 + count * 28
        for definition in definitions {
            for level in 0..<(definition.simple ? 1 : 9) {
                guard var parsed = Self.listLevel(in: table, at: &offset) else { return result }
                let style = definition.styles[level]
                // 0x0FFF — уровень ни с каким стилем не связан.
                if style != 0x0FFF { parsed.paragraphStyle = String(style) }
                result.levels[definition.id, default: [:]][level] = parsed
            }
        }

        // MARK: Экземпляры

        guard let instances = fib.location(of: .plfLfo), instances.fc >= 0, instances.fc + 4 <= table.count else {
            return result
        }
        let instanceCount = Int(Int32(bitPattern: CFBContainerReader.u32(table, instances.fc)))
        guard instanceCount > 0, instances.fc + 4 + instanceCount * 16 <= table.count else { return result }
        var overrides: [Int] = []
        for index in 0..<instanceCount {
            let record = instances.fc + 4 + index * 16
            let numID = String(index + 1)
            result.instances[numID] = String(CFBContainerReader.u32(table, record))
            overrides.append(Int(CFBContainerReader.byte(table, record + 12)))
        }
        // Переопределения: начать заново и свой вид уровня. Битые данные
        // обрывают разбор переопределений, но не списков: без «начать
        // заново» номера местами продолжат счёт, а без списков их не будет
        // вовсе.
        offset = instances.fc + 4 + instanceCount * 16
        for (index, overrideCount) in overrides.enumerated() {
            guard offset + 4 <= table.count else { break }
            offset += 4 // cp: не используется
            let numID = String(index + 1)
            for _ in 0..<overrideCount {
                guard offset + 8 <= table.count else { return result }
                let start = Int(Int32(bitPattern: CFBContainerReader.u32(table, offset)))
                let flags = CFBContainerReader.byte(table, offset + 4)
                offset += 8
                let level = Int(flags & 0x0F)
                guard level <= 8 else { return result }
                let restarts = flags & 0x10 != 0
                if flags & 0x20 != 0 {
                    // Свой вид уровня: начальный номер тогда — в нём.
                    guard let own = Self.listLevel(in: table, at: &offset) else { return result }
                    result.levelOverrides[numID, default: [:]][level] = own
                    if restarts { result.startOverrides[numID, default: [:]][level] = own.start }
                } else if restarts {
                    result.startOverrides[numID, default: [:]][level] = start
                }
            }
        }
        return result
    }

    /// Один уровень `LVL`: `LVLF` (28 байт), свойства абзаца и знаков,
    /// затем строка номера `xst`. Сдвигает `offset` за уровень.
    ///
    /// В строке номера на месте номера уровня N стоит знак с кодом N
    /// (0…8) — он становится `%N+1`, как в `w:lvlText` у `.docx`.
    static func listLevel(in table: Data, at offset: inout Int) -> DocxPartsReader.NumberingTable.Level? {
        guard offset + 28 <= table.count else { return nil }
        var level = DocxPartsReader.NumberingTable.Level()
        level.start = Int(Int32(bitPattern: CFBContainerReader.u32(table, offset)))
        level.format = numberFormat(CFBContainerReader.byte(table, offset + 4))
        level.isLegal = CFBContainerReader.byte(table, offset + 5) & 0x04 != 0
        let characterProperties = Int(CFBContainerReader.byte(table, offset + 24))
        let paragraphProperties = Int(CFBContainerReader.byte(table, offset + 25))
        var position = offset + 28 + paragraphProperties + characterProperties
        guard position + 2 <= table.count else { return nil }
        let length = Int(CFBContainerReader.u16(table, position))
        position += 2
        guard length <= 255, position + length * 2 <= table.count else { return nil }
        var text = ""
        for index in 0..<length {
            let unit = CFBContainerReader.u16(table, position + index * 2)
            if unit < 9 {
                text += "%\(unit + 1)"
            } else if let scalar = Unicode.Scalar(unit) {
                text.unicodeScalars.append(scalar)
            }
        }
        level.text = text
        offset = position + length * 2
        return level
    }

    /// Вид номера по коду `nfc` (MS-OSHARED, MSONFC) — именами `w:numFmt`,
    /// которые понимает общий счётчик. Прочие виды — арабскими цифрами:
    /// номер, записанный иначе, лучше, чем никакого.
    static func numberFormat(_ code: UInt8) -> String {
        switch code {
        case 1: return "upperRoman"
        case 2: return "lowerRoman"
        case 3: return "upperLetter"
        case 4: return "lowerLetter"
        case 22: return "decimalZero"
        case 23: return "bullet"
        case 58: return "russianLower"
        case 59: return "russianUpper"
        case 255: return "none"
        default: return "decimal"
        }
    }
}
