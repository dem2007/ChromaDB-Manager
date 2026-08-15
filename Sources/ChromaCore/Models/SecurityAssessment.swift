import Foundation

/// One thing about the current setup worth saying out loud.
public struct SecurityWarning: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info
        case caution
        case critical

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        public var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .caution: return "exclamationmark.triangle"
            case .critical: return "exclamationmark.octagon"
            }
        }
    }

    public var id: String
    public var severity: Severity
    public var text: String
    public var suggestion: String?

    public init(id: String, severity: Severity, text: String, suggestion: String? = nil) {
        self.id = id
        self.severity = severity
        self.text = text
        self.suggestion = suggestion
    }
}

/// The state of the security screen, computed from the app's own
/// state and nothing else.
///
/// Kept as a plain value so every rule can be checked without a window, a
/// server or a socket: this is the screen a user looks at to decide whether the
/// database is exposed, and being wrong here is worse than being wrong anywhere
/// else in the app.
public struct SecurityAssessment: Sendable {
    public var exposure: NetworkExposure
    public var proxyIsRunning: Bool
    public var proxyPort: Int
    public var serverIsRunning: Bool
    /// Host the ChromaDB process is bound to, when the app started it.
    public var serverHost: String?
    public var serverPort: Int?
    public var clients: [ExternalClient]
    /// How long the proxy has been listening, and whether anything from outside
    /// this machine has actually reached it. Together they are the only way to
    /// tell «никто не подключался» from «файрвол не пускает».
    public var proxyUptime: TimeInterval?
    public var sawExternalRequest: Bool
    /// Настройка «шифровать трафик прокси» — то, что выбрано, а не то,
    /// что происходит сейчас.
    public var usesTLS: Bool
    /// Выпущенный сертификат, если он есть.
    public var certificate: TLSCertificateInfo?
    /// Адреса этого Мака в сети — с ними сверяется, покрывает ли их сертификат.
    public var localAddresses: [String]
    /// Шифрует ли **работающий** прокси. `nil`, когда он остановлен. Отдельно
    /// от `usesTLS` по той же причине, по которой факт вообще отделён
    /// от настройки: настройку можно переключить, не перезапустив прокси.
    public var runningWithTLS: Bool?

    public init(
        exposure: NetworkExposure,
        proxyIsRunning: Bool,
        proxyPort: Int,
        serverIsRunning: Bool,
        serverHost: String? = nil,
        serverPort: Int? = nil,
        clients: [ExternalClient] = [],
        proxyUptime: TimeInterval? = nil,
        sawExternalRequest: Bool = false,
        usesTLS: Bool = true,
        certificate: TLSCertificateInfo? = nil,
        localAddresses: [String] = [],
        runningWithTLS: Bool? = nil
    ) {
        self.proxyUptime = proxyUptime
        self.sawExternalRequest = sawExternalRequest
        self.usesTLS = usesTLS
        self.certificate = certificate
        self.localAddresses = localAddresses
        self.runningWithTLS = runningWithTLS
        self.exposure = exposure
        self.proxyIsRunning = proxyIsRunning
        self.proxyPort = proxyPort
        self.serverIsRunning = serverIsRunning
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.clients = clients
    }

    public var activeClients: [ExternalClient] {
        clients.filter { $0.isEnabled && !$0.isRevoked }
    }

    public var writeClients: [ExternalClient] {
        activeClients.filter { $0.permissions.allowsWrite }
    }

    public var revokedClients: [ExternalClient] {
        clients.filter(\.isRevoked)
    }

    /// Whether the ChromaDB process itself is reachable from the network. This
    /// is the one state the app must never be in.
    public var serverIsExposed: Bool {
        guard serverIsRunning, let host = serverHost else { return false }
        return !Self.isLoopback(host)
    }

    /// Шифруется ли трафик **на самом деле**: у работающего прокси — так, как
    /// он запущен, у остановленного — так, как выбрано. Экран обязан описывать
    /// происходящее, а не намерение: пока прокси работает, значение имеет он.
    public var effectiveTLS: Bool { runningWithTLS ?? usesTLS }

    public static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    /// How long the proxy has to be open before silence means something.
    public static let firewallSuspicionAfter: TimeInterval = 120

    public var warnings: [SecurityWarning] {
        var found: [SecurityWarning] = []

        // Stated always, not only when something is «wrong»: the local server
        // has no authentication of its own, so every process running as this
        // user can reach the database directly, whatever the proxy allows.
        if serverIsRunning {
            found.append(SecurityWarning(
                id: "local-access",
                severity: .info,
                text: String(localized: "Любая программа, запущенная под вашей учётной записью, может обратиться к ChromaDB напрямую на 127.0.0.1 — в обход ключей, прав и лимитов прокси."),
                // Ссылки на внутренний журнал решений в тексте для человека
                // не место: он этого документа не видел и увидеть не может.
                suggestion: String(localized: "Собственной аутентификации у этой версии движка нет — проверено на живом сервере. Прокси защищает от сетевых клиентов, а не от локальных программ.")
            ))
        }

        // The proxy is listening and nothing has arrived from outside: either
        // nobody tried, or macOS is quietly dropping the connections.
        if exposure.isExposed, proxyIsRunning, !sawExternalRequest,
           let uptime = proxyUptime, uptime > Self.firewallSuspicionAfter {
            found.append(SecurityWarning(
                id: "no-external-traffic",
                severity: .caution,
                text: String(localized: "Прокси слушает \(exposure.title) уже \(Int(uptime / 60).plainDigits) мин, но ни одного запроса извне не было."),
                suggestion: String(localized: "Если снаружи подключиться не удаётся, проверьте брандмауэр macOS: при первом открытии порта система спрашивает разрешение на входящие соединения, и без него запросы не доходят.")
            ))
        }

        if serverIsExposed {
            found.append(SecurityWarning(
                id: "server-exposed",
                severity: .critical,
                text: String(localized: "Сервер ChromaDB слушает \(serverHost ?? "?") — к нему можно обратиться по сети напрямую, минуя права доступа."),
                suggestion: String(localized: "У самой ChromaDB нет прав на коллекции и режима «только чтение». Остановите сервер и запустите его на 127.0.0.1, а наружу открывайте прокси.")
            ))
        }

        if exposure.isExposed && proxyIsRunning {
            found.append(SecurityWarning(
                id: "proxy-exposed",
                severity: .caution,
                text: String(localized: "Прокси открыт в локальную сеть на порту \(proxyPort.plainDigits)."),
                suggestion: String(localized: "Подключиться сможет любой, у кого есть действующий ключ. Отзыв ключа действует сразу.")
            ))
        }

        // Наружу и без шифрования — то, ради чего пункт C1 вообще написан.
        // Ключ клиента ходит заголовком: без TLS его читает любой, кто слушает
        // сегмент. Это не «настройка со своими плюсами», а дыра, поэтому
        // предупреждение самое строгое из возможных.
        if exposure.isExposed && !effectiveTLS {
            found.append(SecurityWarning(
                id: "exposed-without-tls",
                severity: .critical,
                text: String(localized: "Прокси открыт в сеть без шифрования: ключ клиента передаётся в открытом виде и виден всем, кто слушает сеть."),
                suggestion: String(localized: "Включите TLS. Если клиент не умеет доверять самоподписанному сертификату, оставьте прокси на 127.0.0.1 — по петле открытый трафик за пределы Мака не выходит.")
            ))
        }

        // Слушать петлю без TLS — нормально, и говорить об этом нечего:
        // такой трафик не покидает машину.
        if usesTLS || runningWithTLS == true, let certificate {
            if certificate.isExpired() {
                found.append(SecurityWarning(
                    id: "certificate-expired",
                    severity: .critical,
                    text: String(localized: "Сертификат прокси истёк \(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))."),
                    suggestion: String(localized: "Клиенты уже получают ошибку. Выпустите сертификат заново и передайте новый отпечаток тем, кто подключается.")
                ))
            } else if certificate.expiresSoon() {
                found.append(SecurityWarning(
                    id: "certificate-expires-soon",
                    severity: .caution,
                    text: String(localized: "Сертификат прокси действует ещё \(certificate.daysRemaining().plainDigits) дн."),
                    suggestion: String(localized: "Перевыпуск меняет отпечаток: клиентам понадобится новый. Лучше сделать это заранее, а не в день, когда всё перестанет работать.")
                ))
            }

            // Адрес Мака в сети сменился, а сертификат остался прежним:
            // клиент получит ошибку имени и будет думать на что угодно, кроме
            // выданного вчера адреса.
            if exposure.isExposed {
                let uncovered = localAddresses.filter { !certificate.covers($0) }
                if !uncovered.isEmpty {
                    found.append(SecurityWarning(
                        id: "certificate-address-mismatch",
                        severity: .caution,
                        text: String(localized: "Сертификат не выписан на адрес этого Мака: \(uncovered.joined(separator: ", "))."),
                        suggestion: String(localized: "Подключение по этому адресу клиент отвергнет по несовпадению имени. Выпустите сертификат заново — новый возьмёт текущие адреса.")
                    ))
                }
            }
        }

        // Настройку переключили, а прокси работает по-старому. Молчать об этом
        // нельзя: экран показывал бы выбранное как действующее, а клиент
        // получал бы обратное — и разбираться в этом пришлось бы на его стороне.
        if proxyIsRunning, let runningWithTLS, runningWithTLS != usesTLS {
            found.append(SecurityWarning(
                id: "tls-restart-needed",
                // Строгость — по тому, что происходит, а не по тому, что
                // выбрано: открытый порт наружу опаснее любого намерения.
                severity: !runningWithTLS && exposure.isExposed ? .critical : .caution,
                text: runningWithTLS
                    ? String(localized: "Шифрование выключено в настройках, но работающий прокси всё ещё шифрует трафик.")
                    : String(localized: "Шифрование включено в настройках, но работающий прокси принимает соединения без него."),
                suggestion: String(localized: "Перезапустите прокси — настройка применяется при запуске.")
            ))
        }

        if exposure.isExposed {
            let unlimited = writeClients.filter { $0.permissions.maxDocumentsPerDay == nil }
            if !unlimited.isEmpty {
                found.append(SecurityWarning(
                    id: "write-without-limit",
                    severity: .caution,
                    text: String(localized: "Право на запись без суточного лимита: \(unlimited.map(\.name).joined(separator: ", "))."),
                    suggestion: String(localized: "При открытом наружу прокси такой ключ может залить в базу сколько угодно документов.")
                ))
            }
            if activeClients.allSatisfy({ $0.permissions.collections.isEmpty }) {
                found.append(SecurityWarning(
                    id: "nothing-permitted",
                    severity: .info,
                    text: String(localized: "Ни одному действующему ключу не разрешена ни одна коллекция."),
                    suggestion: String(localized: "Снаружи подключиться не получится: прокси откажет любому запросу к данным.")
                ))
            }
        }

        if !activeClients.isEmpty && !proxyIsRunning {
            found.append(SecurityWarning(
                id: "proxy-stopped",
                severity: .info,
                text: String(localized: "Прокси остановлен, а ключей заведено: \(activeClients.count.plainDigits)."),
                suggestion: String(localized: "Пока прокси не запущен, внешние клиенты подключиться не могут.")
            ))
        }

        if !revokedClients.isEmpty {
            found.append(SecurityWarning(
                id: "revoked-keys",
                severity: .info,
                text: String(localized: "Клиентов без ключа после отзыва: \(revokedClients.count.plainDigits)."),
                suggestion: String(localized: "Права сохранены. Чтобы клиент заработал снова, выпустите ему новый ключ.")
            ))
        }

        return found.sorted { $0.severity > $1.severity }
    }
}
