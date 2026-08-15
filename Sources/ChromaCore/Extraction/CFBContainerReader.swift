import Foundation

public enum CFBError: LocalizedError, Equatable {
    case notACompoundFile
    case truncated
    case unsupportedSectorSize(Int)
    case streamNotFound(String)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .notACompoundFile:
            return String(localized: "файл не похож на составной документ OLE2")
        case .truncated:
            return String(localized: "составной документ обрезан или повреждён")
        case .unsupportedSectorSize(let size):
            return String(localized: "размер сектора \(size.plainDigits) не поддерживается")
        case .streamNotFound(let name):
            return String(localized: "в документе нет потока «\(name)»")
        case .corrupted(let detail):
            return String(localized: "составной документ повреждён: \(detail)")
        }
    }
}

/// Читалка составных документов OLE2 (Compound File Binary) — контейнера,
/// в котором лежат двоичные `.doc`, `.xls` и `.ppt`.
///
/// Это файловая система внутри файла: заголовок, таблица размещения секторов
/// (FAT), каталог и несколько именованных потоков. У Word это `WordDocument`
/// (заголовок FIB и текст), `1Table` или `0Table` (таблицы диапазонов)
/// и `Data`. Ни текста, ни разметки прямо в файле нет: пока не разобран
/// заголовок и таблица кусков, там просто байты — и именно поэтому раньше
/// про `.doc` нельзя было сказать даже, есть ли в нём комментарии.
///
/// Читается **только** чтение: ни записи, ни изменения, ни удаления потоков —
/// ровно по тем же соображениям, что и у `ZIPContainerReader`, с той же
/// оговоркой, что каждая такая операция была бы способом испортить чужой файл.
public final class CFBContainerReader {
    /// Поток каталога: имя и то, где его искать.
    public struct Entry: Hashable, Sendable {
        public let name: String
        public let size: Int
        /// Первый сектор цепочки. Для маленьких потоков — сектор мини-потока.
        let start: UInt32
        /// 2 — поток, 5 — корень, 1 — «папка».
        let type: UInt8

        public var isStream: Bool { type == 2 }
    }

    /// Особые значения в цепочках FAT.
    private enum Sector {
        static let endOfChain: UInt32 = 0xFFFF_FFFE
        static let free: UInt32 = 0xFFFF_FFFF
        static let fat: UInt32 = 0xFFFF_FFFD
        static let difat: UInt32 = 0xFFFF_FFFC
        /// Больше этого номера сектора в живом файле не бывает.
        static let maxRegular: UInt32 = 0xFFFF_FFFA
    }

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: Data
    public let entries: [Entry]

    /// Сколько байт файл может занять в памяти. Отображение (`mappedIfSafe`)
    /// делает предел вопросом адресного пространства, а не оперативной памяти,
    /// но собранные потоки копируются, и предел остаётся осмысленным.
    public static let maxFileSize = 512 * 1024 * 1024

    public init(url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw CFBError.notACompoundFile
        }
        // Подпись — раньше длины: короткий файл, который и не собирался быть
        // составным документом, должен получить ответ «это не он», а не
        // «он повреждён».
        let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard data.count >= 8, (0..<8).allSatisfy({ Self.byte(data, $0) == signature[$0] }) else {
            throw CFBError.notACompoundFile
        }
        guard data.count >= 512 else { throw CFBError.truncated }
        guard data.count <= Self.maxFileSize else {
            throw CFBError.corrupted(String(localized: "файл больше предела чтения"))
        }
        self.data = data

        let sectorShift = Int(Self.u16(data, 30))
        let miniShift = Int(Self.u16(data, 32))
        guard sectorShift == 9 || sectorShift == 12 else {
            throw CFBError.unsupportedSectorSize(1 << max(0, min(31, sectorShift)))
        }
        guard miniShift == 6 else { throw CFBError.unsupportedSectorSize(1 << max(0, min(31, miniShift))) }
        self.sectorSize = 1 << sectorShift
        self.miniSectorSize = 1 << miniShift
        self.miniCutoff = Int(Self.u32(data, 56))

        // DIFAT: где лежат секторы FAT. Первые 109 номеров — в самом заголовке,
        // остальные — цепочкой отдельных секторов, и только у больших файлов.
        var fatSectors: [UInt32] = []
        for index in 0..<109 {
            let sector = Self.u32(data, 76 + index * 4)
            if sector > Sector.maxRegular { continue }
            fatSectors.append(sector)
        }
        var difatSector = Self.u32(data, 68)
        let difatCount = Int(Self.u32(data, 72))
        var difatSeen = 0
        while difatSector <= Sector.maxRegular, difatSeen <= difatCount, difatSeen < 1_000_000 {
            let base = (Int(difatSector) + 1) * sectorSize
            guard base + sectorSize <= data.count else { throw CFBError.truncated }
            let perSector = sectorSize / 4 - 1
            for index in 0..<perSector {
                let sector = Self.u32(data, base + index * 4)
                if sector > Sector.maxRegular { continue }
                fatSectors.append(sector)
            }
            difatSector = Self.u32(data, base + perSector * 4)
            difatSeen += 1
        }

        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectors.count * (sectorSize / 4))
        for sector in fatSectors {
            let base = (Int(sector) + 1) * sectorSize
            guard base + sectorSize <= data.count else { throw CFBError.truncated }
            for index in 0..<(sectorSize / 4) {
                fat.append(Self.u32(data, base + index * 4))
            }
        }
        guard !fat.isEmpty else { throw CFBError.corrupted(String(localized: "нет таблицы размещения")) }
        self.fat = fat

        // Каталог: цепочка секторов по 128 байт на запись.
        let directory = try Self.chain(
            from: Self.u32(data, 48), fat: fat, data: data, sectorSize: sectorSize, limit: nil
        )
        var entries: [Entry] = []
        var index = 0
        while (index + 1) * 128 <= directory.count {
            let base = index * 128
            let type = Self.byte(directory, base + 66)
            index += 1
            guard type == 1 || type == 2 || type == 5 else { continue }
            let nameLength = Int(Self.u16(directory, base + 64))
            guard nameLength >= 2, nameLength <= 64 else { continue }
            var units: [UInt16] = []
            for position in stride(from: 0, to: nameLength - 2, by: 2) {
                units.append(Self.u16(directory, base + position))
            }
            let name = String(decoding: units, as: UTF16.self)
            // Размер потока — 8 байт, но у версии 3 старшие четыре не значат
            // ничего; и то и другое ограничено размером файла.
            let size = Int(Self.u32(directory, base + 120))
            entries.append(Entry(name: name, size: size, start: Self.u32(directory, base + 116), type: type))
        }
        guard let root = entries.first(where: { $0.type == 5 }) else {
            throw CFBError.corrupted(String(localized: "в каталоге нет корневой записи"))
        }
        self.entries = entries

        // Мини-FAT и мини-поток: всё, что мельче порога (обычно 4 КБ), лежит
        // не в секторах файла, а внутри одного потока корневой записи.
        var miniFAT: [UInt32] = []
        let miniFATSectors = Int(Self.u32(data, 64))
        if miniFATSectors > 0 {
            let raw = try Self.chain(
                from: Self.u32(data, 60), fat: fat, data: data, sectorSize: sectorSize,
                limit: miniFATSectors * sectorSize
            )
            miniFAT.reserveCapacity(raw.count / 4)
            for position in stride(from: 0, to: raw.count - 3, by: 4) {
                miniFAT.append(Self.u32(raw, position))
            }
        }
        self.miniFAT = miniFAT
        self.miniStream = miniFAT.isEmpty ? Data() : (try Self.chain(
            from: root.start, fat: fat, data: data, sectorSize: sectorSize, limit: root.size
        ))
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name && $0.isStream }
    }

    /// Байты потока целиком. Потоки Word — единицы мегабайт в худшем случае,
    /// и разбирать их по кускам смысла нет: таблица кусков всё равно ходит
    /// по потоку вразнобой.
    public func read(_ name: String) throws -> Data {
        guard let entry = entry(named: name) else { throw CFBError.streamNotFound(name) }
        guard entry.size > 0 else { return Data() }
        if entry.size < miniCutoff {
            return try Self.chain(
                from: entry.start, fat: miniFAT, data: miniStream,
                sectorSize: miniSectorSize, limit: entry.size, offsetsFromStart: true
            )
        }
        return try Self.chain(
            from: entry.start, fat: fat, data: data, sectorSize: sectorSize, limit: entry.size
        )
    }

    // MARK: - Цепочки

    /// Сектора цепочки подряд. `offsetsFromStart` — для мини-потока, где сектор
    /// номер N лежит по смещению N·64 от начала, а не через сектор заголовка.
    private static func chain(
        from start: UInt32, fat: [UInt32], data: Data, sectorSize: Int,
        limit: Int?, offsetsFromStart: Bool = false
    ) throws -> Data {
        var result = Data()
        if let limit { result.reserveCapacity(limit) }
        var sector = start
        var visited = 0
        while sector <= Sector.maxRegular {
            // Зацикленную цепочку файл описать может — прочитать её нельзя.
            visited += 1
            guard visited <= fat.count + 1 else {
                throw CFBError.corrupted(String(localized: "цепочка секторов зациклена"))
            }
            let base = offsetsFromStart ? Int(sector) * sectorSize : (Int(sector) + 1) * sectorSize
            guard base >= 0, base + sectorSize <= data.count else { throw CFBError.truncated }
            result.append(data[(data.startIndex + base)..<(data.startIndex + base + sectorSize)])
            if let limit, result.count >= limit { break }
            guard Int(sector) < fat.count else { throw CFBError.truncated }
            sector = fat[Int(sector)]
        }
        if let limit, result.count > limit { result = result.prefix(limit) }
        return Data(result)
    }

    // MARK: - Чтение чисел

    static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        guard offset >= 0, offset < data.count else { return 0 }
        return data[data.startIndex + offset]
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < data.count else { return 0 }
        return UInt16(byte(data, offset)) | (UInt16(byte(data, offset + 1)) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < data.count else { return 0 }
        return UInt32(u16(data, offset)) | (UInt32(u16(data, offset + 2)) << 16)
    }
}
