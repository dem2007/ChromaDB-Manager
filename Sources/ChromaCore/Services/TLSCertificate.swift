import Foundation
import CryptoKit
import Security

/// Что известно о сертификате прокси — ровно то, что показывается человеку.
public struct TLSCertificateInfo: Sendable, Equatable {
    /// Имя в поле subject. Оно же issuer: сертификат самоподписанный.
    public var commonName: String
    public var notBefore: Date
    public var notAfter: Date
    /// SHA-256 самого сертификата, группами по два знака через двоеточие —
    /// в том же виде, в каком его показывают браузеры и `openssl x509
    /// -fingerprint -sha256`. Клиенту сверять придётся глазами, поэтому вид
    /// должен совпадать с тем, что он увидит у себя.
    public var fingerprint: String
    /// Имена и адреса, на которые сертификат действителен (SAN).
    public var hosts: [String]

    public init(commonName: String, notBefore: Date, notAfter: Date, fingerprint: String, hosts: [String]) {
        self.commonName = commonName
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.fingerprint = fingerprint
        self.hosts = hosts
    }

    /// За сколько дней до конца срока об этом стоит сказать.
    public static let warningDays = 30

    public func isExpired(asOf now: Date = Date()) -> Bool { now >= notAfter }

    public func daysRemaining(asOf now: Date = Date()) -> Int {
        Int((notAfter.timeIntervalSince(now) / 86400).rounded(.down))
    }

    public func expiresSoon(asOf now: Date = Date()) -> Bool {
        !isExpired(asOf: now) && daysRemaining(asOf: now) <= Self.warningDays
    }

    /// Действителен ли сертификат для этого адреса. Нужен не ради красоты:
    /// адрес Мака в сети меняется, а сертификат остаётся прежним — и клиент,
    /// который вчера подключался, сегодня получит ошибку имени, ничего
    /// не поняв. Экран «Безопасность» предупреждает об этом заранее.
    public func covers(_ host: String) -> Bool {
        hosts.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
    }
}

public enum TLSCertificateError: LocalizedError {
    case keyGenerationFailed(String)
    case signingFailed(String)
    case malformedCertificate
    case missing
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let reason):
            return String(localized: "Не удалось создать ключ сертификата: \(reason)")
        case .signingFailed(let reason):
            return String(localized: "Не удалось подписать сертификат: \(reason)")
        case .malformedCertificate:
            return String(localized: "Сертификат повреждён и не читается.")
        case .missing:
            return String(localized: "Сертификат ещё не выпущен.")
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)"
            return String(localized: "Ошибка Keychain: \(message)")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformedCertificate, .missing:
            return String(localized: "Выпустите сертификат заново на экране «Безопасность» — старый при этом заменяется, клиентам понадобится новый отпечаток.")
        default:
            return nil
        }
    }
}

/// Выпускает и хранит самоподписанный сертификат прокси.
///
/// **Приватный ключ живёт в Keychain и оттуда не выходит** — подпись делает
/// сама Security, ключ не выгружается ни в файл, ни в память приложения.
/// Сертификат, наоборот, лежит обычным файлом: он не секрет, его отдают
/// клиенту, и держать его в Keychain незачем. Проверено на живой системе:
/// `SecIdentityCreateWithCertificate` собирает идентичность для `NWListener`,
/// когда в Keychain есть только ключ.
///
/// Почему не «сертификат тоже в Keychain, найдём по ярлыку»: ярлык, заданный
/// при добавлении, система молча заменяет на subject — поиск по своему ярлыку
/// не находит ничего. Ключ ищется по `kSecAttrApplicationTag`, и он работает.
public final class TLSCertificateService: @unchecked Sendable {
    private let tag: Data
    private let label: String
    private let file: URL
    private let lock = NSLock()

    /// Имя внутри сертификата. Латиницей, и это не про красоту: common name
    /// уходит в чужие инструменты, и кириллица в нём вылезает у клиента
    /// экранированными байтами вида `\D1\82`. Найдено сквозным тестом через
    /// `curl`. На проверку имени хоста CN всё равно не влияет — за это отвечает
    /// SAN, — так что читаемость важнее.
    public static let certificateCommonName = "ChromaDB Manager Proxy"

    public init(
        tag: String = "io.github.chromadbmanager.tls",
        label: String = "ChromaDB Manager (прокси)",
        file: URL = AppPaths.tlsCertificateFile
    ) {
        self.tag = Data(tag.utf8)
        self.label = label
        self.file = file
    }

    // MARK: - Чтение

    /// Сертификат, выпущенный прежде, или `nil`. Ключа без сертификата
    /// не бывает: если файл потерян, считаем, что сертификата нет.
    public func current() -> TLSCertificateInfo? {
        guard let der = certificateData(), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return nil
        }
        return Self.describe(certificate: certificate, der: der)
    }

    public func certificateData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: file)
    }

    /// Сертификат в PEM — в этом виде его принимают `curl --cacert`, Python
    /// `requests` и почти всё остальное.
    public func certificatePEM() throws -> String {
        guard let der = certificateData() else { throw TLSCertificateError.missing }
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }

    public func export(to url: URL) throws {
        try certificatePEM().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Выпуск

    /// Имена, на которые выписывается сертификат: этот Мак под всеми адресами,
    /// по которым к нему сегодня можно обратиться.
    public static func defaultHosts() -> [String] {
        var hosts = ["localhost", "127.0.0.1"]
        let name = ProcessInfo.processInfo.hostName
        if !name.isEmpty && !hosts.contains(name) { hosts.append(name) }
        for address in LocalNetwork.addresses() where !hosts.contains(address) {
            hosts.append(address)
        }
        return hosts
    }

    /// Выпускает новый сертификат, заменяя прежний вместе с ключом.
    ///
    /// Замена — это всегда разрыв: у клиентов остаётся старый отпечаток,
    /// и до обновления они получат ошибку. Поэтому перевыпуск делается
    /// только по явной команде или когда сертификата нет вовсе.
    @discardableResult
    public func issue(hosts: [String]? = nil, days: Int = 365, now: Date = Date()) throws -> TLSCertificateInfo {
        let names = (hosts ?? Self.defaultHosts()).filter { !$0.isEmpty }
        lock.lock()
        defer { lock.unlock() }

        // Прежний ключ **не удаляется заранее**. Удалить его первым действием
        // значило бы: не удалось создать новый (связка заблокирована) или
        // записать сертификат — и работавший TLS уничтожен, а на экране
        // по-прежнему старый отпечаток, будто всё в порядке. Поэтому старые
        // ключи запоминаются, новый создаётся рядом, и только после успешной
        // записи прежние убираются.
        let previous = existingKeys()
        let privateKey = try makeKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            delete(keys: [privateKey])
            throw TLSCertificateError.keyGenerationFailed("нет публичной части")
        }

        // Всё, что может не получиться, делается до единого разрушительного
        // шага. Не получилось — убираем за собой новый ключ и уходим, оставив
        // прежнюю пару работать.
        do {
            let der = try CertificateBuilder.selfSigned(
                privateKey: privateKey,
                publicKey: publicKey,
                commonName: Self.certificateCommonName,
                hosts: names,
                days: days,
                now: now
            )
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
                  let info = Self.describe(certificate: certificate, der: der) else {
                throw TLSCertificateError.malformedCertificate
            }

            try AppPaths.ensureDirectory(file.deletingLastPathComponent())
            try der.write(to: file, options: .atomic)

            // Точка невозврата пройдена: новый сертификат на диске, и старые
            // ключи больше ни к чему не подходят.
            delete(keys: previous)
            return info
        } catch {
            delete(keys: [privateKey])
            throw error
        }
    }

    /// Возвращает действующий сертификат, выпуская его, только если его нет
    /// вовсе, он истёк или к нему потерян ключ.
    ///
    /// **Смена адреса машины сертификат не перевыпускает**, и это осознанно.
    /// Ноутбук переезжает из дома в офис по нескольку раз в неделю; если
    /// перевыпускать по несовпадению адреса, отпечаток менялся бы при каждом
    /// переезде, и все, кому его выдали, отваливались бы без объяснений.
    /// Перевыпуск разрывает доверие, поэтому он остаётся решением человека:
    /// про непокрытый адрес говорит предупреждение на экране «Безопасность».
    @discardableResult
    public func ensure(hosts: [String]? = nil, now: Date = Date()) throws -> TLSCertificateInfo {
        if let existing = current(), !existing.isExpired(asOf: now), hasKey() {
            return existing
        }
        return try issue(hosts: hosts, now: now)
    }

    /// Идентичность для `NWListener`. Собирается из сертификата и ключа
    /// в Keychain — ключ при этом никуда не копируется.
    public func identity() throws -> SecIdentity {
        guard let der = certificateData(), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TLSCertificateError.missing
        }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw TLSCertificateError.keychain(status)
        }
        return identity
    }

    /// Убирает и ключ, и сертификат. Вызывается «удалением всех данных»:
    /// приложение, которое обещает стереть за собой всё, не должно оставлять
    /// в Keychain ключ.
    public func remove() {
        lock.lock()
        defer { lock.unlock() }
        removeKey()
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Keychain

    private func makeKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrLabel as String: label,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let reason = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "неизвестная причина"
            throw TLSCertificateError.keyGenerationFailed(reason)
        }
        return key
    }

    private func hasKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func removeKey() {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ] as CFDictionary)
    }

    /// Ключи приложения, лежащие в связке сейчас. В норме один; два бывают
    /// только внутри перевыпуска, между созданием нового и удалением старого.
    private func existingKeys() -> [SecKey] {
        var found: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &found)
        guard status == errSecSuccess else { return [] }
        if let list = found as? [SecKey] { return list }
        if let single = found, CFGetTypeID(single) == SecKeyGetTypeID() {
            return [single as! SecKey]
        }
        return []
    }

    /// Удаляет **именно эти** ключи, а не всё по метке: во время перевыпуска
    /// по метке лежат и новый, и старый.
    private func delete(keys: [SecKey]) {
        for key in keys {
            SecItemDelete([
                kSecClass as String: kSecClassKey,
                kSecValueRef as String: key,
            ] as CFDictionary)
        }
    }

    // MARK: - Разбор

    static func describe(certificate: SecCertificate, der: Data) -> TLSCertificateInfo? {
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]],
              let from = seconds(values[kSecOIDX509V1ValidityNotBefore as String]),
              let until = seconds(values[kSecOIDX509V1ValidityNotAfter as String]) else {
            return nil
        }
        return TLSCertificateInfo(
            commonName: subject,
            notBefore: Date(timeIntervalSinceReferenceDate: from),
            notAfter: Date(timeIntervalSinceReferenceDate: until),
            fingerprint: fingerprint(of: der),
            hosts: SubjectAltNameReader.hosts(in: der)
        )
    }

    private static func seconds(_ entry: [String: Any]?) -> Double? {
        (entry?[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue
    }

    public static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Построение сертификата

enum CertificateBuilder {
    // OID'ы, которые нужны. Числа выписаны, а не «взяты из константы»: своих
    // констант для них в Security нет, и именованное поле здесь честнее.
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"
    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    static let commonNameOID = "2.5.4.3"
    static let basicConstraints = "2.5.29.19"
    static let keyUsage = "2.5.29.15"
    static let extendedKeyUsage = "2.5.29.37"
    static let subjectAltName = "2.5.29.17"
    static let serverAuth = "1.3.6.1.5.5.7.3.1"

    static func name(_ text: String) -> [UInt8] {
        ASN1.sequence([ASN1.set([ASN1.sequence([
            ASN1.objectIdentifier(commonNameOID),
            ASN1.utf8String(text),
        ])])])
    }

    /// SAN. Без него современный клиент откажет, **даже доверяя сертификату**:
    /// common name как имя хоста не читается уже давно. Проверено `curl`'ом.
    static func subjectAlternativeNames(_ hosts: [String]) -> [UInt8] {
        var entries: [[UInt8]] = []
        for host in hosts {
            if let octets = ipv4(host) {
                entries.append(ASN1.tagged(0x87, octets))
            } else {
                entries.append(ASN1.tagged(0x82, Array(host.utf8)))
            }
        }
        return ASN1.sequence(entries)
    }

    static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    static func extensions(hosts: [String]) -> [UInt8] {
        func extensionEntry(_ oid: String, critical: Bool, _ value: [UInt8]) -> [UInt8] {
            var items: [[UInt8]] = [ASN1.objectIdentifier(oid)]
            if critical { items.append(ASN1.boolean(true)) }
            items.append(ASN1.octetString(value))
            return ASN1.sequence(items)
        }
        return ASN1.explicit(3, ASN1.sequence([
            // Самоподписанный сертификат подписывает сам себя, то есть
            // выступает удостоверяющим центром для самого себя.
            extensionEntry(basicConstraints, critical: true, ASN1.sequence([ASN1.boolean(true)])),
            // digitalSignature (0), keyEncipherment (2) и — обязательно —
            // keyCertSign (5).
            //
            // Без `keyCertSign` OpenSSL отказывается считать сертификат
            // издателем самого себя и отвечает «unable to get local issuer
            // certificate», даже когда файл передан ему как доверенный.
            // Найдено живой проверкой настоящим клиентом: `curl` на macOS
            // такой сертификат принимал, Python — нет. Ровно тот случай,
            // ради которого пункт проверяется вживую, а не только тестом.
            extensionEntry(keyUsage, critical: true, ASN1.namedBits([0, 2, 5])),
            extensionEntry(extendedKeyUsage, critical: false, ASN1.sequence([ASN1.objectIdentifier(serverAuth)])),
            extensionEntry(subjectAltName, critical: false, subjectAlternativeNames(hosts)),
        ]))
    }

    static func selfSigned(
        privateKey: SecKey,
        publicKey: SecKey,
        commonName subject: String,
        hosts: [String],
        days: Int,
        now: Date
    ) throws -> Data {
        guard let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw TLSCertificateError.keyGenerationFailed("публичный ключ не выгружается")
        }

        let algorithm = ASN1.sequence([ASN1.objectIdentifier(ecdsaWithSHA256)])
        let publicKeyInfo = ASN1.sequence([
            ASN1.sequence([ASN1.objectIdentifier(ecPublicKey), ASN1.objectIdentifier(prime256v1)]),
            ASN1.bitString(Array(point)),
        ])

        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F

        let tbs = ASN1.sequence([
            ASN1.explicit(0, ASN1.integer([0x02])),  // v3
            ASN1.integer(serial),
            algorithm,
            name(subject),
            // Пять минут назад, а не «сейчас»: часы клиента и сервера сходятся
            // не всегда, а сертификат «из будущего» отвергается молча.
            ASN1.sequence([
                ASN1.utcTime(now.addingTimeInterval(-300)),
                ASN1.utcTime(now.addingTimeInterval(Double(days) * 86400)),
            ]),
            name(subject),
            publicKeyInfo,
            extensions(hosts: hosts),
        ])

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(tbs) as CFData,
            &error
        ) as Data? else {
            let reason = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "неизвестная причина"
            throw TLSCertificateError.signingFailed(reason)
        }

        return Data(ASN1.sequence([tbs, algorithm, ASN1.bitString(Array(signature))]))
    }
}

// MARK: - Чтение SAN

/// Достаёт из сертификата список имён, на которые он выписан.
///
/// Почему свой проход, когда есть `SecCertificateCopyValues`: она отдаёт SAN
/// разобранным, но подписывает записи **локализованными** метками — «DNS Name»
/// по-английски и по-русски по-разному, — и служебная строка «Critical» приходит
/// такой же строкой, как имя. Отличать имя от пометки по локализованному тексту
/// значит сломаться при первой же смене языка системы. Срок действия берётся
/// у Security как раньше: там значение числовое и от языка не зависит.
enum SubjectAltNameReader {
    static func hosts(in der: Data) -> [String] {
        let bytes = [UInt8](der)
        guard let extensionValue = findExtension(oid: CertificateBuilder.subjectAltName, in: bytes) else { return [] }
        return generalNames(in: extensionValue)
    }

    /// Заголовок TLV: тег, длина содержимого, смещение содержимого.
    private static func header(_ bytes: [UInt8], _ index: Int) -> (tag: UInt8, length: Int, start: Int)? {
        guard index + 1 < bytes.count else { return nil }
        let tag = bytes[index]
        let first = bytes[index + 1]
        if first < 0x80 { return (tag, Int(first), index + 2) }
        let count = Int(first & 0x7F)
        guard count > 0, index + 1 + count < bytes.count else { return nil }
        var length = 0
        for offset in 0..<count { length = length << 8 | Int(bytes[index + 2 + offset]) }
        return (tag, length, index + 2 + count)
    }

    /// Ищет расширение по OID, обходя дерево целиком. Обход всего дерева вместо
    /// хождения по известным полям — потому что структура сертификата
    /// не наша забота: нужен один OCTET STRING рядом с известным OID.
    private static func findExtension(oid: String, in bytes: [UInt8]) -> [UInt8]? {
        let target = ASN1.objectIdentifier(oid)
        var index = 0
        while index < bytes.count {
            guard let head = header(bytes, index) else { return nil }
            let end = head.start + head.length
            guard end <= bytes.count else { return nil }

            // Составной тег — заходим внутрь.
            let isConstructed = head.tag & 0x20 != 0
            if isConstructed {
                if head.tag == 0x30, matchesExtension(bytes, head, target: target),
                   let value = extensionValue(bytes, head) {
                    return value
                }
                index = head.start
                continue
            }
            index = end
        }
        return nil
    }

    /// Начинается ли эта SEQUENCE с искомого OID.
    private static func matchesExtension(_ bytes: [UInt8], _ head: (tag: UInt8, length: Int, start: Int), target: [UInt8]) -> Bool {
        guard head.start + target.count <= bytes.count else { return false }
        return Array(bytes[head.start..<(head.start + target.count)]) == target
    }

    /// Содержимое OCTET STRING внутри `Extension ::= SEQUENCE { OID, BOOLEAN OPTIONAL, OCTET STRING }`.
    private static func extensionValue(_ bytes: [UInt8], _ head: (tag: UInt8, length: Int, start: Int)) -> [UInt8]? {
        var index = head.start
        let end = head.start + head.length
        while index < end {
            guard let field = header(bytes, index) else { return nil }
            if field.tag == 0x04 {
                let valueEnd = field.start + field.length
                guard valueEnd <= bytes.count else { return nil }
                return Array(bytes[field.start..<valueEnd])
            }
            index = field.start + field.length
        }
        return nil
    }

    /// `GeneralNames ::= SEQUENCE OF GeneralName`; нас интересуют `dNSName [2]`
    /// и `iPAddress [7]`.
    private static func generalNames(in bytes: [UInt8]) -> [String] {
        guard let outer = header(bytes, 0), outer.tag == 0x30 else { return [] }
        var index = outer.start
        let end = min(outer.start + outer.length, bytes.count)
        var found: [String] = []
        while index < end {
            guard let entry = header(bytes, index) else { break }
            let valueEnd = min(entry.start + entry.length, bytes.count)
            let value = Array(bytes[entry.start..<valueEnd])
            switch entry.tag {
            case 0x82:
                if let text = String(bytes: value, encoding: .utf8) { found.append(text) }
            case 0x87 where value.count == 4:
                found.append(value.map { String($0) }.joined(separator: "."))
            default:
                break
            }
            index = valueEnd
        }
        return found
    }
}
