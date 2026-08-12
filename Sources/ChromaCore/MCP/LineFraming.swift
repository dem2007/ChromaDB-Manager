import Foundation

/// Разбор потока на сообщения, разделённые переводом строки.
///
/// Кадрирование stdio по спецификации MCP: одно сообщение JSON-RPC на строку,
/// UTF-8, переводов строк внутри сообщения быть не может. Спецификация прямо
/// говорит, что произвольным транспортам поверх надёжного двунаправленного
/// потока — сокетам Unix в том числе — следует брать это же кадрирование
///. Поэтому кодек один: и на стандартных потоках, и на сокете между
/// вспомогательным файлом и приложением.
public struct LineFramer: Sendable {
    /// Хвост, не окончившийся переводом строки. Чтение из потока режет данные
    /// как попало, и сообщение регулярно приходит двумя кусками.
    private var pending = Data()

    /// Предел длины одной строки.
    ///
    /// Без него отправитель, забывший перевод строки, заставил бы нас копить
    /// его поток до исчерпания памяти. 16 МиБ — заведомо больше любого
    /// осмысленного сообщения и заведомо меньше беды.
    public static let lineLimit = 16 * 1024 * 1024

    public init() {}

    public enum FramingError: Error, Equatable {
        case lineTooLong(Int)
    }

    /// Добавляет прочитанный кусок и возвращает все сообщения, которые из него
    /// сложились целиком.
    public mutating func consume(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            pending = pending[pending.index(after: newline)...]
            // Пустые строки пропускаем молча: отправитель, поставивший лишний
            // перевод строки, не нарушил ничего важного, а ошибка разбора
            // на пустоте выглядела бы загадкой.
            if !line.isEmpty { messages.append(Data(line)) }
        }
        // Переиндексация: срез сохраняет исходные индексы, и без этого
        // `startIndex` уползал бы всё дальше от нуля.
        pending = Data(pending)
        guard pending.count <= Self.lineLimit else {
            throw FramingError.lineTooLong(pending.count)
        }
        return messages
    }

    /// Остаток без завершающего перевода строки.
    ///
    /// Нужен при закрытии потока: последнее сообщение отправителя вполне может
    /// прийти без него, и молча потерять его нельзя.
    public mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : Data(pending)
    }
}

public enum LineFraming {
    /// Готовит сообщение к отправке.
    ///
    /// Перевод строки просто дописывается: `JSONEncoder` экранирует переводы
    /// строк внутри строковых значений (`\n`), поэтому в закодированном
    /// сообщении сырого перевода строки быть не может — то самое требование
    /// спецификации «сообщение не содержит переводов строк» выполняется
    /// само собой, и закрыто тестом.
    public static func frame(_ message: Data) -> Data {
        var framed = message
        framed.append(UInt8(ascii: "\n"))
        return framed
    }
}
