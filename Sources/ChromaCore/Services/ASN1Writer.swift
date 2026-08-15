import Foundation

/// Минимальный кодировщик DER — ровно столько, сколько нужно, чтобы выписать
/// сертификат X.509.
///
/// Зачем он вообще: в macOS **нет** публичного API, который выпускает
/// сертификат. `SecCertificateCreateWithData` умеет только разобрать готовый,
/// а всё, что выпускает, живёт внутри `certtool` и в закрытых частях Security.
/// Проверено на живой системе перед тем, как писать эту строку. Тянуть ради
/// одного сертификата OpenSSL — значит завести первую в проекте стороннюю
/// зависимость, да ещё и с собственной историей уязвимостей; выписать двести
/// байт структуры руками дешевле.
///
/// Здесь только запись. Чтение обратно — срок действия и список имён — делает
/// сама Security через `SecCertificateCopyValues`: разбирать чужой DER своими
/// руками незачем и опаснее.
enum ASN1 {
    /// Длина в DER: до 127 — одним байтом, дальше «сколько байтов, потом они».
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tagged(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + length(body.count) + body
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tagged(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tagged(0x31, items.flatMap { $0 }) }

    /// INTEGER. Знака у нас нет, поэтому ведущий бит ≥ 0x80 требует нулевого
    /// байта впереди — иначе число прочитается отрицательным.
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var value = bytes
        while value.count > 1 && value[0] == 0 && value[1] < 0x80 { value.removeFirst() }
        if value.isEmpty { value = [0] }
        if let first = value.first, first >= 0x80 { value.insert(0, at: 0) }
        return tagged(0x02, value)
    }

    /// BIT STRING. Первый байт — сколько бит в конце не используется.
    static func bitString(_ bytes: [UInt8], unusedBits: Int = 0) -> [UInt8] {
        tagged(0x03, [UInt8(unusedBits)] + bytes)
    }

    /// Именованные биты (`KeyUsage` и подобные): номера установленных бит
    /// считаются от старшего в первом байте.
    ///
    /// Хвост здесь не формальность. Незначащие биты в конце обязаны быть
    /// объявлены: строгий разборщик читает `KeyUsage` ровно по этой длине,
    /// а нестрогий — как повезёт.
    static func namedBits(_ positions: [Int]) -> [UInt8] {
        guard let highest = positions.max() else { return bitString([], unusedBits: 0) }
        var bytes = [UInt8](repeating: 0, count: highest / 8 + 1)
        for position in positions {
            bytes[position / 8] |= UInt8(0x80 >> (position % 8))
        }
        return bitString(bytes, unusedBits: 7 - highest % 8)
    }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tagged(0x04, bytes) }
    static func boolean(_ value: Bool) -> [UInt8] { tagged(0x01, [value ? 0xFF : 0x00]) }
    static func utf8String(_ text: String) -> [UInt8] { tagged(0x0C, Array(text.utf8)) }

    /// Время в UTCTime — две цифры года. Формат X.509 для дат до 2049 года;
    /// сертификаты приложения живут год, так что до GeneralizedTime дело
    /// не дойдёт.
    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return tagged(0x17, Array(formatter.string(from: date).utf8))
    }

    /// Явный контекстный тег `[n]`.
    static func explicit(_ number: UInt8, _ body: [UInt8]) -> [UInt8] {
        tagged(0xA0 | number, body)
    }

    /// OID из точечной записи. Первые две дуги пакуются в один байт, остальные
    /// — по семь бит с продолжением.
    static func objectIdentifier(_ text: String) -> [UInt8] {
        let parts = text.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return tagged(0x06, []) }
        var body: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(part & 0x7F)]
            var value = part >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            body += chunk
        }
        return tagged(0x06, body)
    }
}
