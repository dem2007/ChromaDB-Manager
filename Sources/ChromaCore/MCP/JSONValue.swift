import Foundation

/// Произвольное значение JSON.
///
/// MCP возит параметры и результаты инструментов как свободный JSON: схему
/// каждого инструмента объявляем мы сами, а транспорт обязан пронести что
/// угодно, не заглядывая внутрь. `Codable`-типа на «что угодно» в стандартной
/// библиотеке нет, поэтому он здесь.
///
/// Числа разделены на целые и дробные намеренно. `n_results: 10`, пройдя через
/// `Double`, вернулось бы наружу как `10.0` — формально то же число, фактически
/// другой JSON, и агент, сверяющий ответ со схемой `"type": "integer"`, получил
/// бы отказ.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // Целое пробуется раньше дробного: `decode(Double.self)` принял бы
            // и его, молча превратив 10 в 10.0.
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Значение не является JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Чтение

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        // 10.0 от агента — это 10. Отвергать такое значило бы придираться
        // к тому, как чужой сериализатор записал целое число.
        //
        // Но **только** если число в `Int` помещается. `Int(_: Double)` за
        // границей диапазона — не отказ, а фатальная ошибка: процесс падает
        // целиком, вместе с чужими запросами и открытыми соединениями.
        // А проверка «целое ли» тут не помогает: у чисел больше 2^53 дробной
        // части не бывает вовсе, и `1e19 == 1e19.rounded()` — правда.
        // `Int(exactly:)` отвечает `nil`, а вызывающий уже умеет сказать
        // «параметр должен быть целым числом».
        case .double(let value) where value == value.rounded(): return Int(exactly: value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Поле объекта или `nil`, если это не объект.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Элемент массива по номеру. Выход за границы — `nil`, а не падение:
    /// разбирается чужой JSON, и «блока с таким номером нет» — обычный случай,
    /// а не ошибка программиста.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    /// Значение обратно в текст JSON — им задаётся `where` для ChromaDB.
    ///
    /// Ключи упорядочены: одинаковый фильтр обязан давать одинаковую строку,
    /// иначе она не сравнивается ни в тесте, ни в журнале.
    public var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public extension JSONValue {
    /// Во сколько **знаков** обойдётся это значение в ответе агенту.
    ///
    /// Свойство самого значения, а не того, кто его собрал: бюджет ответа
    /// тратят и рендер документов, и перечень файлов у `collect_mentions`, и
    /// мерка у них обязана быть одна (…).
    ///
    /// Считается по настоящему JSON, а не на глаз: у документа с метаданными
    /// зеркало выходит **тяжелее** своего текста — измерено 24 358 против
    /// 17 923, — и всякая прикидка вроде «столько же» промахивается.
    ///
    /// Знаки, а не байты. Потолок ключа назван в знаках — так он
    /// объявлен агенту и так называется в правах (`maxResponseCharacters`), —
    /// а здесь считались байты UTF-8. На кириллице это вдвое больше, и
    /// бюджет, складывавший знаки текста с байтами зеркала, урезал русский
    /// ответ до 17 280 знаков из обещанных 24 000. Единица у обещания
    /// и у счёта обязана быть одна.
    var deliveredSize: Int {
        guard let data = try? JSONValue.sizingEncoder.encode(self) else { return 0 }
        return String(decoding: data, as: UTF8.self).count
    }

    /// Один на всех: настраивать в нём нечего, а зовут его на каждый документ
    /// и каждый файл выдачи.
    private static let sizingEncoder = JSONEncoder()
}
