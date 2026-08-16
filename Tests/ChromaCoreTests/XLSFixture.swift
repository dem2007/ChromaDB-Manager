import Foundation

/// Сборщик старых книг Excel (BIFF8) для проверок.
///
/// Собирается здесь, а не берётся готовым файлом, по той же причине, что
/// и `DocFixture`: разбирается формат, а не чья-то книга, и каждая ловушка —
/// общая строка, разорванная границей записи, дата под встроенной маской,
/// сжатое число — должна быть выразима.
struct XLSFixture {
    enum Cell {
        /// Текст через таблицу общих строк — так Excel хранит его обычно.
        case shared(String)
        /// Текст прямо в записи ячейки.
        case inline(String)
        case number(Double)
        /// Число, записанное сжатым видом.
        case compact(Int)
        case date(Double)
        case boolean(Bool)
        /// Формула с кэшированным числом.
        case formula(Double)
        /// Формула с кэшированной строкой.
        case formulaText(String)
        case blank
    }

    struct Sheet {
        var name: String
        var isHidden = false
        var rows: [[Cell]]
    }

    var sheets: [Sheet]
    var uses1904 = false
    /// Сколько лишних общих строк дописать, чтобы таблица не влезла в одну
    /// запись и поехали продолжения.
    var padStrings = 0

    func build() -> Data {
        // Общие строки: сначала собираем, потом нумеруем.
        var shared: [String] = []
        var index: [String: Int] = [:]
        func number(_ text: String) -> Int {
            if let existing = index[text] { return existing }
            shared.append(text)
            index[text] = shared.count - 1
            return shared.count - 1
        }
        for sheet in sheets {
            for row in sheet.rows {
                for cell in row { if case .shared(let text) = cell { _ = number(text) } }
            }
        }
        for position in 0..<padStrings { _ = number("Заполнение \(position) " + String(repeating: "дл", count: 40)) }

        // Стили: 0 — обычный, 1 — дата (встроенная маска 14).
        var globals = Data()
        globals.append(record(0x0809, u16(0x0600) + u16(0x0005) + Data(count: 12)))
        globals.append(record(0x0022, u16(uses1904 ? 1 : 0)))
        globals.append(record(0x00E0, u16(0) + u16(0) + Data(count: 16)))
        globals.append(record(0x00E0, u16(0) + u16(14) + Data(count: 16)))

        // Смещения листов известны только после сборки заголовка, поэтому
        // сначала считаем длину глобального подпотока с местами под них.
        var boundSheets = Data()
        for sheet in sheets {
            boundSheets.append(record(0x0085, u32(0) + u16(sheet.isHidden ? 1 : 0) + shortString(sheet.name)))
        }
        globals.append(boundSheets)
        globals.append(sharedStringsRecords(shared))
        globals.append(record(0x000A, Data()))

        var body = Data()
        var offsets: [Int] = []
        for sheet in sheets {
            offsets.append(globals.count + body.count)
            body.append(record(0x0809, u16(0x0600) + u16(0x0010) + Data(count: 12)))
            for (rowNumber, row) in sheet.rows.enumerated() {
                for (columnNumber, cell) in row.enumerated() {
                    body.append(self.cell(cell, row: rowNumber, column: columnNumber, shared: index))
                }
            }
            body.append(record(0x000A, Data()))
        }

        // Проставляем настоящие смещения листов на их места.
        var stream = globals + body
        // Записи BOUNDSHEET ищутся заново: так надёжнее, чем считать смещения.
        var position = 0
        var sheetIndex = 0
        while position + 4 <= stream.count, sheetIndex < offsets.count {
            let type = UInt16(stream[position]) | (UInt16(stream[position + 1]) << 8)
            let length = Int(UInt16(stream[position + 2]) | (UInt16(stream[position + 3]) << 8))
            if type == 0x0085 {
                let bytes = u32(UInt32(offsets[sheetIndex]))
                stream.replaceSubrange((position + 4)..<(position + 8), with: bytes)
                sheetIndex += 1
            }
            position += 4 + length
        }

        return DocFixture.container(streams: [(name: "Workbook", data: stream)])
    }

    // MARK: - Записи

    private func cell(_ cell: Cell, row: Int, column: Int, shared: [String: Int]) -> Data {
        let head = u16(UInt16(row)) + u16(UInt16(column))
        switch cell {
        case .shared(let text):
            return record(0x00FD, head + u16(0) + u32(UInt32(shared[text] ?? 0)))
        case .inline(let text):
            return record(0x0204, head + u16(0) + longString(text))
        case .number(let value):
            return record(0x0203, head + u16(0) + double(value))
        case .compact(let value):
            return record(0x027E, head + u16(0) + u32(UInt32(bitPattern: Int32(value) << 2 | 0x02)))
        case .date(let serial):
            return record(0x0203, head + u16(1) + double(serial))
        case .boolean(let value):
            return record(0x0205, head + u16(0) + Data([value ? 1 : 0, 0]))
        case .formula(let value):
            return record(0x0006, head + u16(0) + double(value) + Data(count: 8))
        case .formulaText(let text):
            let marker = Data([0, 0, 0, 0, 0, 0, 0xFF, 0xFF])
            return record(0x0006, head + u16(0) + marker + Data(count: 8))
                + record(0x0207, longString(text))
        case .blank:
            return record(0x0201, head + u16(0))
        }
    }

    /// Таблица общих строк записями, как её пишет Excel.
    ///
    /// Запись не длиннее 8224 байт, и продолжение начинается **с признака
    /// сжатия**, если строка через него переходит; заголовок строки при этом
    /// никогда не разрывается. Делить как попало нельзя — иначе фикстура
    /// проверяет не формат, а собственную ошибку.
    private func sharedStringsRecords(_ strings: [String]) -> Data {
        let limit = 8224
        var records: [Data] = [Data()]
        var payload: Data { records[records.count - 1] }

        func room() -> Int { limit - records[records.count - 1].count }
        func open() {
            records.append(Data())
        }
        func write(_ bytes: Data) {
            records[records.count - 1].append(bytes)
        }

        write(u32(UInt32(strings.count)) + u32(UInt32(strings.count)))
        for text in strings {
            let units = Array(text.utf16)
            // Заголовок целиком в одной записи: три байта.
            if room() < 3 { open() }
            write(u16(UInt16(units.count)) + Data([0x01]))
            var written = 0
            while written < units.count {
                if room() < 2 {
                    open()
                    // Продолжение строки — со своим признаком сжатия.
                    write(Data([0x01]))
                }
                write(u16(units[written]))
                written += 1
            }
        }
        _ = payload

        var result = Data()
        for (index, piece) in records.enumerated() where !piece.isEmpty {
            result += u16(index == 0 ? 0x00FC : 0x003C) + u16(UInt16(piece.count)) + piece
        }
        return result
    }

    /// Запись BIFF, при нужде разбитая на продолжения: длина записи —
    /// два байта, больше 8224 байт в неё не кладут.
    private func record(_ type: UInt16, _ payload: Data) -> Data {
        let limit = 8224
        guard payload.count > limit else {
            return u16(type) + u16(UInt16(payload.count)) + payload
        }
        var result = u16(type) + u16(UInt16(limit)) + payload.prefix(limit)
        var rest = payload.dropFirst(limit)
        while !rest.isEmpty {
            let piece = rest.prefix(limit)
            result += u16(0x003C) + u16(UInt16(piece.count)) + piece
            rest = rest.dropFirst(piece.count)
        }
        return result
    }

    // MARK: - Числа и строки

    private func u16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }

    private func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    private func double(_ value: Double) -> Data {
        var bits = value.bitPattern
        var result = Data()
        for _ in 0..<8 {
            result.append(UInt8(bits & 0xFF))
            bits >>= 8
        }
        return result
    }

    /// Строка с однобайтовой длиной — так пишутся имена листов.
    private func shortString(_ text: String) -> Data {
        let units = Array(text.utf16)
        var result = Data([UInt8(min(units.count, 255)), 0x01])
        for unit in units { result += u16(unit) }
        return result
    }

    /// Строка с двухбайтовой длиной, всегда двухбайтовыми знаками:
    /// кириллица в однобайтовую половину таблицы всё равно не укладывается.
    private func longString(_ text: String) -> Data {
        let units = Array(text.utf16)
        var result = u16(UInt16(units.count)) + Data([0x01])
        for unit in units { result += u16(unit) }
        return result
    }
}
