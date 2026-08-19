import Foundation
import UserNotifications

/// Something the user should hear about even with the window closed.
///
/// Deliberately a short list. A notification for every event is a notification
/// for none of them, so this covers the three things that change what the user
/// would do next: the server died, someone was refused at the proxy, and the
/// emergency stop went through.
public enum SecurityEvent: Sendable, Equatable {
    case serverFailed(String)
    case accessDenied(client: String, reason: String)
    case emergencyStop(revokedKeys: Int)

    var title: String {
        switch self {
        case .serverFailed: return String(localized: "Сервер ChromaDB остановился")
        case .accessDenied: return String(localized: "Отказ в доступе")
        case .emergencyStop: return String(localized: "Экстренная остановка выполнена")
        }
    }

    var body: String {
        switch self {
        case .serverFailed(let reason):
            return reason
        case .accessDenied(let client, let reason):
            return "\(client): \(reason)"
        case .emergencyStop(let revoked):
            return revoked == 0
                ? String(localized: "Сервер и прокси остановлены.")
                : String(localized: "Сервер и прокси остановлены, отозвано ключей: \(revoked.plainDigits).")
        }
    }

    /// Refusals arrive in bursts — a misconfigured client retries in a loop —
    /// and are collapsed into one notification per window. The other two are
    /// single events and are never collapsed.
    var isCollapsible: Bool {
        if case .accessDenied = self { return true }
        return false
    }
}

/// Notification Center, with the two facts that decide whether it works at all.
///
/// **A bundle is required.** `UNUserNotificationCenter.current()` does not fail
/// gracefully outside an app bundle — it raises `bundleProxyForCurrentProcess
/// is nil` and takes the process with it (verified: a plain `swiftc` binary
/// dies at that line). `swift run` produces exactly such a binary, so the
/// availability check is not defensive programming, it is the difference
/// between a running app and a crash on launch.
///
/// **Permission is asked once, when the switch is turned on** — not at launch,
/// because an app that asks for notifications before it has anything to say
/// gets denied.
@MainActor
public final class Notifier: ObservableObject {
    public enum Availability: Equatable {
        case unknown
        case ready
        case denied
        /// No bundle: `swift run`, tests, anything not launched as an app.
        case unsupported(String)

        public var isReady: Bool { self == .ready }
    }

    /// How a notification actually reaches the user. Injected so tests never
    /// touch the real Notification Center.
    public typealias Delivery = @Sendable (_ title: String, _ body: String) -> Void
    public typealias AuthorizationRequest = @Sendable () async -> Result<Bool, Error>

    @Published public private(set) var availability: Availability = .unknown
    /// Set from the settings; nothing is posted while this is off.
    @Published public var isEnabled = false

    private let deliver: Delivery
    private let requestAuthorization: AuthorizationRequest
    private let log: LogHandler
    private let collapseWindow: TimeInterval
    private var lastCollapsedPost: Date?
    private var suppressedSinceLastPost = 0

    public init(
        log: @escaping LogHandler = noopLogHandler,
        collapseWindow: TimeInterval = 60,
        deliver: Delivery? = nil,
        requestAuthorization: AuthorizationRequest? = nil
    ) {
        self.log = log
        self.collapseWindow = collapseWindow
        self.deliver = deliver ?? Notifier.systemDelivery
        self.requestAuthorization = requestAuthorization ?? Notifier.systemAuthorization
        if deliver == nil && !Notifier.isSupported {
            availability = .unsupported(String(localized: "приложение запущено не как бандл .app"))
        }
        // Only for the real notification centre: a test with an injected
        // delivery closure must not reach for `UNUserNotificationCenter`.
        if deliver == nil {
            installForegroundPresenter()
        }
    }

    /// Whether the process can talk to Notification Center at all.
    /// `nonisolated`: the delivery closures run wherever they are called from,
    /// and this is the check that keeps them from crashing there.
    ///
    /// Спрашивается **расширение бандла**, а не наличие идентификатора.
    /// Идентификатор есть и у процесса `xctest`, а `UNUserNotificationCenter`
    /// у него всё равно падает с `bundleProxyForCurrentProcess is nil` — то
    /// есть проверка отвечала на соседний вопрос, а не на свой (тот же
    /// класс дефекта, что и). Пока приложение запускали только
    /// как `.app`, разница не проявлялась; как только слой экранов стал
    /// тестируемым, первый же тест уронил процесс.
    public nonisolated static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Turning it on

    /// Asks for permission and reports whether notifications will now arrive.
    /// Called from the switch, so the user sees the system prompt as a direct
    /// consequence of their own action.
    @discardableResult
    public func enable() async -> Bool {
        if case .unsupported(let reason) = availability {
            isEnabled = false
            log(.warning, "Уведомления", "Уведомления недоступны: \(reason)")
            return false
        }
        switch await requestAuthorization() {
        case .success(true):
            availability = .ready
            isEnabled = true
            log(.success, "Уведомления", "Уведомления включены")
            return true
        case .success(false):
            availability = .denied
            isEnabled = false
            log(.warning, "Уведомления", "macOS не разрешил уведомления для приложения")
            return false
        case .failure(let error):
            availability = .unsupported(error.localizedDescription)
            isEnabled = false
            log(.error, "Уведомления", "Не удалось запросить разрешение: \(error.localizedDescription)")
            return false
        }
    }

    public func disable() {
        isEnabled = false
    }

    // MARK: - Posting

    public func post(_ event: SecurityEvent) {
        guard isEnabled, availability != .denied else { return }
        if case .unsupported = availability { return }

        if event.isCollapsible, let last = lastCollapsedPost, Date().timeIntervalSince(last) < collapseWindow {
            suppressedSinceLastPost += 1
            return
        }

        var body = event.body
        if event.isCollapsible {
            if suppressedSinceLastPost > 0 {
                body += String(localized: "\nЕщё отклонено запросов: \(suppressedSinceLastPost.plainDigits).")
            }
            lastCollapsedPost = Date()
            suppressedSinceLastPost = 0
        }
        deliver(event.title, body)
    }

    /// Refusals that were collapsed into the next notification — shown on the
    /// security screen so the count is not invented by the notification alone.
    public var pendingCollapsedCount: Int { suppressedSinceLastPost }

    /// The summary of a finished background operation.
    ///
    /// Kept apart from `post(_ event:)` on purpose: security events are about
    /// something going wrong right now and are governed by the master switch
    /// alone, while these are the outcome of work the user started and walked
    /// away from — and are governed by their own three-way setting. Folding the
    /// two together would mean either silencing a failed server along with
    /// routine syncs, or waking the user for every timer run.
    @discardableResult
    public func post(_ notice: OperationNotice, policy: OperationNotificationPolicy) -> Bool {
        guard isEnabled, availability != .denied else { return false }
        if case .unsupported = availability { return false }
        guard notice.shouldPost(policy: policy) else { return false }
        deliver(notice.title, notice.body)
        return true
    }

    // MARK: - The real thing

    /// macOS shows no banner for a notification posted while the app is
    /// frontmost: without a delegate it goes straight into Notification Center,
    /// unseen. For «сервер упал» that is the opposite of the point, and the one
    /// summary H4 promises would never appear to a user who is looking at the
    /// window. Found by waiting for a banner that never came.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound, .list])
        }
    }

    /// The delegate is held weakly by the notification centre, so it has to be
    /// owned here or it disappears and banners quietly stop.
    private let presenter = ForegroundPresenter()

    private func installForegroundPresenter() {
        guard Notifier.isSupported else { return }
        UNUserNotificationCenter.current().delegate = presenter
    }

    private static let systemDelivery: Delivery = { title, body in
        guard Notifier.isSupported else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static let systemAuthorization: AuthorizationRequest = {
        guard Notifier.isSupported else {
            return .success(false)
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return .success(granted)
        } catch {
            return .failure(error)
        }
    }
}
