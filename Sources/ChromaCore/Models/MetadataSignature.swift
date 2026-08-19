import Foundation

/// Подпись полей, с которыми записаны чанки файла.
///
/// Существует ради одного вопроса, задаваемого задним числом: **какие поля
/// лежат сейчас в базе у этого файла?** Настройки источника отвечают на другой
/// вопрос — какие поля пишутся *сегодня*, — а разница между ответами и есть
/// работа: что дописать, а что убрать. Векторы при этом не трогаются: текст
/// не менялся, менялись подписи к нему.
///
/// Формат разбирается обратно, поэтому список ключей стоит **первым** и
/// отдельно от значений: значение ручного поля бывает любым, а ключ — короткое
/// слово, и путать одно с другим при разборе нельзя.
public struct MetadataSignature: Hashable, Sendable {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    /// Знаки, которые в списке ключей значат разделитель, а не букву ключа.
    ///
    /// Ключ уровня проверяется на латиницу, но ручное поле источника человек
    /// вводит как хочет — и ключ с запятой разобрался бы обратно как два
    /// чужих ключа, которые обновление полей послушно удалило бы из базы.
    /// Поэтому ключи в подписи кодируются, а не пишутся как есть.
    private static let keySafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))

    private static func encode(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: keySafe) ?? key
    }

    private static func decode(_ key: String) -> String {
        key.removingPercentEncoding ?? key
    }

    /// Подпись нынешних настроек источника.
    public static func of(_ source: DataSource) -> MetadataSignature {
        let keys = source.writtenMetadataKeys.sorted().map(encode).joined(separator: ",")
        let levels = source.pathLevels.enumerated()
            .filter { $0.element.isNamed }
            .map { "\($0.offset + 1)=\($0.element.trimmedKey):\($0.element.type.rawValue):\($0.element.fallbackValue)" }
            .joined(separator: ",")
        let custom = source.customMetadata.keys.filter { !$0.isEmpty }.sorted()
            .map { "\($0)=\(source.customMetadata[$0] ?? "")" }
            .joined(separator: ",")
        return MetadataSignature(
            "keys:[\(keys)]/map:\(source.mapping.rawValue)/levels:[\(levels)]/custom:[\(custom)]"
        )
    }

    /// Ключи, которые писались с этой подписью.
    ///
    /// Пустая подпись — запись прежней сборки: что там писалось, неизвестно,
    /// и удалять по догадке нельзя. Тогда обновление только дописывает.
    public var writtenKeys: Set<String> {
        guard let start = text.range(of: "keys:[") else { return [] }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return [] }
        return Set(
            rest[..<end]
                .split(separator: ",")
                .map { Self.decode($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        )
    }

    public var isUnknown: Bool { text.isEmpty }
}
