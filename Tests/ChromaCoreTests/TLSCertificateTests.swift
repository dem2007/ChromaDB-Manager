import XCTest
import Security
@testable import ChromaCore

/// Сертификат приложение выписывает само, байт за байтом, — значит проверять
/// надо не «вызвался ли API», а то, что получилось: разбирает ли это Security,
/// те ли имена внутри, тот ли срок, тот ли отпечаток.
final class TLSCertificateTests: XCTestCase {
    // MARK: - DER

    func testLengthShortForm() {
        XCTAssertEqual(ASN1.length(0), [0x00])
        XCTAssertEqual(ASN1.length(127), [0x7F])
    }

    func testLengthLongForm() {
        // 128 уже не помещается в короткую форму: старший бит занят признаком.
        XCTAssertEqual(ASN1.length(128), [0x81, 0x80])
        XCTAssertEqual(ASN1.length(300), [0x82, 0x01, 0x2C])
        XCTAssertEqual(ASN1.length(65536), [0x83, 0x01, 0x00, 0x00])
    }

    func testObjectIdentifierMatchesKnownEncoding() {
        // ecdsa-with-SHA256, значение известно и проверяемо по RFC 5758.
        XCTAssertEqual(
            ASN1.objectIdentifier("1.2.840.10045.4.3.2"),
            [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        )
        // commonName — самый короткий из используемых.
        XCTAssertEqual(ASN1.objectIdentifier("2.5.4.3"), [0x06, 0x03, 0x55, 0x04, 0x03])
    }

    func testIntegerPadsWhenHighBitSet() {
        // Без нуля впереди 0x80 прочитается как отрицательное число.
        XCTAssertEqual(ASN1.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
        XCTAssertEqual(ASN1.integer([0x7F]), [0x02, 0x01, 0x7F])
        // Лишние нули убираются, но не в ущерб знаку.
        XCTAssertEqual(ASN1.integer([0x00, 0x01]), [0x02, 0x01, 0x01])
        XCTAssertEqual(ASN1.integer([0x00, 0x80]), [0x02, 0x02, 0x00, 0x80])
    }

    // MARK: - Адреса

    func testIPv4Recognition() {
        XCTAssertEqual(CertificateBuilder.ipv4("192.168.1.42"), [192, 168, 1, 42])
        XCTAssertEqual(CertificateBuilder.ipv4("127.0.0.1"), [127, 0, 0, 1])
        XCTAssertNil(CertificateBuilder.ipv4("localhost"))
        XCTAssertNil(CertificateBuilder.ipv4("mac.local"))
        // 999 не байт — это имя, а не адрес, и в SAN должно уйти как имя.
        XCTAssertNil(CertificateBuilder.ipv4("1.2.3.999"))
        XCTAssertNil(CertificateBuilder.ipv4("192.168.1"))
    }

    // MARK: - Сертификат целиком

    /// Ключ на один тест: без `kSecAttrIsPermanent` он не попадает в Keychain,
    /// поэтому проверка построения не зависит ни от связки ключей, ни от того,
    /// на какой машине идёт.
    private func ephemeralKey() throws -> (private: SecKey, public: SecKey) {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key) else {
            throw XCTSkip("система не выдала ключ P-256: \(String(describing: error?.takeRetainedValue()))")
        }
        return (key, publicKey)
    }

    private func buildCertificate(
        hosts: [String] = ["localhost", "127.0.0.1"],
        days: Int = 365,
        now: Date = Date()
    ) throws -> Data {
        let keys = try ephemeralKey()
        return try CertificateBuilder.selfSigned(
            privateKey: keys.private,
            publicKey: keys.public,
            commonName: "ChromaDB Manager (тест)",
            hosts: hosts,
            days: days,
            now: now
        )
    }

    func testSecurityParsesWhatWeBuilt() throws {
        let der = try buildCertificate()
        // Главная проверка построения: то, что мы выписали руками, читает
        // сама система, а не только наш собственный разбор.
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let summary = SecCertificateCopySubjectSummary(certificate) as String?
        XCTAssertEqual(summary, "ChromaDB Manager (тест)")
    }

    func testValidityMatchesRequestedPeriod() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let der = try buildCertificate(days: 30, now: now)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let info = try XCTUnwrap(TLSCertificateService.describe(certificate: certificate, der: der))

        XCTAssertEqual(info.notAfter.timeIntervalSince(now), 30 * 86400, accuracy: 60)
        // Срок начинается чуть раньше «сейчас»: часы клиента могут отставать.
        XCTAssertLessThan(info.notBefore, now)
        XCTAssertEqual(info.daysRemaining(asOf: now), 30)
        XCTAssertFalse(info.isExpired(asOf: now))
    }

    func testHostsSurviveTheRoundTrip() throws {
        let hosts = ["localhost", "mac-max.local", "127.0.0.1", "192.168.1.42"]
        let der = try buildCertificate(hosts: hosts)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let info = try XCTUnwrap(TLSCertificateService.describe(certificate: certificate, der: der))

        XCTAssertEqual(info.hosts, hosts, "имена должны читаться обратно ровно те же и в том же порядке")
    }

    func testSubjectAltNameReaderIgnoresLocalisedLabels() throws {
        // Разбор идёт по тегам DER, а не по подписям вроде «DNS Name»:
        // их система переводит, и на другом языке чтение бы развалилось.
        let der = try buildCertificate(hosts: ["example.local", "10.0.0.5"])
        XCTAssertEqual(SubjectAltNameReader.hosts(in: der), ["example.local", "10.0.0.5"])
    }

    func testHostCoverageIsCaseInsensitive() throws {
        let der = try buildCertificate(hosts: ["Mac-Max.local", "127.0.0.1"])
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let info = try XCTUnwrap(TLSCertificateService.describe(certificate: certificate, der: der))

        XCTAssertTrue(info.covers("mac-max.local"))
        XCTAssertTrue(info.covers("127.0.0.1"))
        XCTAssertFalse(info.covers("192.168.1.42"), "адрес, которого в сертификате нет, покрытым считаться не должен")
    }

    func testFingerprintLooksLikeEveryOtherToolShowsIt() throws {
        let der = try buildCertificate()
        let fingerprint = TLSCertificateService.fingerprint(of: der)
        let groups = fingerprint.split(separator: ":")
        XCTAssertEqual(groups.count, 32, "SHA-256 — 32 байта")
        XCTAssertTrue(groups.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) })
        XCTAssertEqual(fingerprint, fingerprint.uppercased())
    }

    func testFingerprintChangesWithTheCertificate() throws {
        let first = try buildCertificate()
        let second = try buildCertificate()
        XCTAssertNotEqual(
            TLSCertificateService.fingerprint(of: first),
            TLSCertificateService.fingerprint(of: second),
            "перевыпуск обязан менять отпечаток — иначе клиент не заметит подмены"
        )
    }

    // MARK: - Срок

    func testExpiryWarningWindow() throws {
        let now = Date()
        func info(daysLeft: Double) -> TLSCertificateInfo {
            TLSCertificateInfo(
                commonName: "тест",
                notBefore: now.addingTimeInterval(-86400),
                notAfter: now.addingTimeInterval(daysLeft * 86400),
                fingerprint: "AA",
                hosts: []
            )
        }
        XCTAssertFalse(info(daysLeft: 90).expiresSoon(asOf: now))
        XCTAssertTrue(info(daysLeft: 29).expiresSoon(asOf: now))
        XCTAssertTrue(info(daysLeft: 0.5).expiresSoon(asOf: now))
        // Истёкший не «скоро истечёт» — он уже не работает, и сказать надо иначе.
        XCTAssertFalse(info(daysLeft: -1).expiresSoon(asOf: now))
        XCTAssertTrue(info(daysLeft: -1).isExpired(asOf: now))
    }

    // MARK: - Служба целиком

    /// Служба трогает Keychain. Если связка недоступна (бывает на сборочной
    /// машине), тест честно пропускается, а не «проходит».
    private func makeService() throws -> (TLSCertificateService, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tls-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = TLSCertificateService(
            tag: "io.github.chromadbmanager.tests.\(UUID().uuidString)",
            label: "ChromaDB Manager (тест)",
            file: directory.appendingPathComponent("certificate.der")
        )
        return (service, directory)
    }

    func testIssueThenReadBackThenRemove() throws {
        let (service, directory) = try makeService()
        defer {
            service.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNil(service.current(), "до выпуска сертификата нет")
        let issued: TLSCertificateInfo
        do {
            issued = try service.issue(hosts: ["localhost", "127.0.0.1"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }

        let read = try XCTUnwrap(service.current())
        XCTAssertEqual(read.fingerprint, issued.fingerprint)
        XCTAssertEqual(read.hosts, ["localhost", "127.0.0.1"])

        // Идентичность собирается — то, ради чего всё и делается.
        XCTAssertNoThrow(try service.identity())

        service.remove()
        XCTAssertNil(service.current(), "после удаления не должно остаться ни файла, ни ключа")
        XCTAssertThrowsError(try service.identity())
    }

    func testEnsureKeepsTheCertificateItAlreadyHas() throws {
        let (service, directory) = try makeService()
        defer {
            service.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        let first: TLSCertificateInfo
        do {
            first = try service.ensure(hosts: ["localhost"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }
        let second = try service.ensure(hosts: ["localhost"])
        XCTAssertEqual(first.fingerprint, second.fingerprint, "лишний перевыпуск ломает подключения клиентов")
    }

    /// Смена адреса машины сертификат **не** перевыпускает.
    ///
    /// Раньше перевыпускала, и это было хуже, чем кажется: ноутбук переезжает
    /// из дома в офис по нескольку раз в неделю, и при каждом переезде
    /// отпечаток менялся бы молча, а все, кому его выдали, отваливались бы
    /// без объяснений. Перевыпуск рвёт доверие, поэтому остаётся решением
    /// человека; про непокрытый адрес говорит предупреждение на экране.
    func testEnsureKeepsTheCertificateWhenTheAddressChanges() throws {
        let (service, directory) = try makeService()
        defer {
            service.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        let first: TLSCertificateInfo
        do {
            first = try service.ensure(hosts: ["localhost"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }
        let second = try service.ensure(hosts: ["localhost", "192.168.1.42"])
        XCTAssertEqual(first.fingerprint, second.fingerprint, "молчаливая смена отпечатка ломает всех клиентов разом")
        XCTAssertFalse(second.covers("192.168.1.42"), "непокрытый адрес остаётся непокрытым — о нём предупреждают, а не чинят втихую")
    }

    /// Неудачный перевыпуск не должен уничтожать работающую пару.
    func testAFailedReissueLeavesTheWorkingCertificateAlone() throws {
        let (service, directory) = try makeService()
        defer {
            service.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        let good: TLSCertificateInfo
        do {
            good = try service.issue(hosts: ["localhost"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }

        // Запись сертификата провалится: на месте файла теперь каталог.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("certificate.der"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("certificate.der"),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try service.issue(hosts: ["localhost"]))

        // Ключ прежней пары обязан остаться: иначе неудачная попытка
        // перевыпуска уносит с собой рабочий TLS.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("certificate.der"))
        let restored = try service.issue(hosts: ["localhost"])
        XCTAssertNotEqual(restored.fingerprint, good.fingerprint, "это уже новый сертификат")
        XCTAssertNoThrow(try service.identity(), "к новому сертификату обязан находиться его ключ")
    }

    func testEnsureReissuesExpired() throws {
        let (service, directory) = try makeService()
        defer {
            service.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        let past = Date().addingTimeInterval(-400 * 86400)
        let expired: TLSCertificateInfo
        do {
            expired = try service.issue(hosts: ["localhost"], days: 1, now: past)
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }
        XCTAssertTrue(expired.isExpired())

        let fresh = try service.ensure(hosts: ["localhost"])
        XCTAssertFalse(fresh.isExpired())
        XCTAssertNotEqual(fresh.fingerprint, expired.fingerprint)
    }

    func testExportedPEMIsWhatToolsExpect() throws {
        let (service, directory) = try makeService()
        defer {
            service.remove()
            try? FileManager.default.removeItem(at: directory)
        }

        do {
            _ = try service.issue(hosts: ["localhost"])
        } catch {
            throw XCTSkip("Keychain недоступен: \(error.localizedDescription)")
        }

        let pem = try service.certificatePEM()
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END CERTIFICATE-----\n"))

        // Обратный путь: base64 из PEM должен снова стать тем же сертификатом.
        let body = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let decoded = try XCTUnwrap(Data(base64Encoded: body))
        XCTAssertEqual(decoded, service.certificateData())

        let file = directory.appendingPathComponent("exported.pem")
        try service.export(to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), pem)
    }

    func testDefaultHostsAlwaysCoverThisMachineLocally() {
        let hosts = TLSCertificateService.defaultHosts()
        XCTAssertTrue(hosts.contains("localhost"))
        XCTAssertTrue(hosts.contains("127.0.0.1"))
        XCTAssertEqual(Set(hosts).count, hosts.count, "повторов в SAN быть не должно")
    }
}
