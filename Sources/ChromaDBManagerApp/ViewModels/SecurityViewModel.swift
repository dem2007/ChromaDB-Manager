import Foundation
import SwiftUI
import AppKit
import ChromaCore

/// The «Безопасность» screen: what is exposed right now, the switch
/// that exposes it, and the one button that takes it all down.
@MainActor
final class SecurityViewModel: ObservableObject {
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isBusy = false
    /// Both destructive actions ask first — opening the proxy to the network
    /// and taking everything down are not things to do by mis-click.
    @Published var isConfirmingExposure = false
    @Published var isConfirmingStop = false

    // MARK: - Exposure

    func requestExposure(_ exposure: NetworkExposure, app: AppEnvironment) {
        guard exposure != app.settings.configuration.proxyExposure else { return }
        if exposure.isExposed {
            isConfirmingExposure = true
        } else {
            apply(exposure, app: app)
        }
    }

    func confirmExposure(_ app: AppEnvironment) {
        apply(.allInterfaces, app: app)
    }

    private func apply(_ exposure: NetworkExposure, app: AppEnvironment) {
        let wasRunning = app.proxy.state.isRunning
        app.settings.configuration.proxyExposure = exposure
        app.settings.saveNow()
        errorMessage = nil

        guard wasRunning else {
            statusMessage = exposure.isExposed
                ? String(localized: "Прокси будет открыт в локальную сеть при следующем запуске.")
                : String(localized: "Прокси будет слушать только этот компьютер.")
            return
        }
        // A listener cannot change what it is bound to; it has to be replaced.
        app.proxy.stop()
        do {
            try app.startProxy()
            statusMessage = exposure.isExposed
                ? String(localized: "Прокси перезапущен и слушает все интерфейсы.")
                : String(localized: "Прокси перезапущен и слушает только 127.0.0.1.")
        } catch {
            // Rolled back, because leaving the setting on «наружу» with a dead
            // listener would show an exposure that does not exist.
            app.settings.configuration.proxyExposure = .loopback
            app.settings.saveNow()
            errorMessage = app.describe(error)
        }
    }

    // MARK: - Notifications

    func setNotifications(_ isOn: Bool, app: AppEnvironment) async {
        if isOn {
            let granted = await app.notifier.enable()
            app.settings.configuration.notificationsEnabled = granted
            if !granted {
                errorMessage = String(localized: "macOS не разрешил уведомления. Проверьте «Системные настройки» → «Уведомления» → ChromaDB Manager.")
            }
        } else {
            app.notifier.disable()
            app.settings.configuration.notificationsEnabled = false
        }
    }

    // MARK: - Emergency stop

    func emergencyStop(_ app: AppEnvironment) async {
        isBusy = true
        errorMessage = nil
        let revoked = await app.emergencyStop()
        isBusy = false
        statusMessage = revoked == 0
            ? String(localized: "Сервер и прокси остановлены. Действующих ключей не было.")
            : String(localized: "Сервер и прокси остановлены, отозвано ключей: \(revoked.plainDigits). Права клиентов сохранены — выпустите новые ключи на экране «Клиенты».")
    }

    // MARK: - Сертификат

    /// Перевыпуск спрашивает подтверждения: он разрывает связь со всеми, кто
    /// уже доверился прежнему отпечатку.
    @Published var isConfirmingReissue = false

    /// Включает или выключает шифрование. Прокси перезапускается, если работал:
    /// слушателю режим задаётся при создании, на лету он не меняется.
    func setTLS(_ isOn: Bool, app: AppEnvironment) {
        guard isOn != app.settings.configuration.proxyUsesTLS else { return }
        let wasRunning = app.proxy.state.isRunning
        app.settings.configuration.proxyUsesTLS = isOn
        app.settings.saveNow()
        errorMessage = nil

        guard wasRunning else {
            statusMessage = isOn
                ? String(localized: "Прокси будет шифровать трафик при следующем запуске.")
                : String(localized: "Прокси будет принимать соединения без шифрования при следующем запуске.")
            return
        }
        app.proxy.stop()
        do {
            try app.startProxy()
            statusMessage = isOn
                ? String(localized: "Прокси перезапущен и шифрует трафик.")
                : String(localized: "Прокси перезапущен и работает без шифрования.")
        } catch {
            // Откат по той же причине, что и у режима доступа: настройка,
            // не совпавшая с действительностью, — это неверный экран.
            app.settings.configuration.proxyUsesTLS = !isOn
            app.settings.saveNow()
            errorMessage = app.describe(error)
            // И прокси поднимается обратно. Без этого неудачное переключение
            // роняло работавший прокси насовсем: настройка вернулась, клиенты
            // отвалились, и об этом нигде не сказано.
            restart(app, after: error)
        }
    }

    /// Возвращает прокси в строй после неудачной попытки перезапустить его
    /// с новыми настройками.
    private func restart(_ app: AppEnvironment, after failure: Error) {
        do {
            try app.startProxy()
            errorMessage = String(localized: "\(app.describe(failure)) Прокси перезапущен с прежними настройками.")
        } catch {
            errorMessage = String(localized: "\(app.describe(failure)) Прокси остановлен: \(app.describe(error))")
        }
    }

    func reissueCertificate(_ app: AppEnvironment) {
        errorMessage = nil
        // Первый выпуск и перевыпуск — одно действие, но не одна новость:
        // «выпущен заново» на пустом месте заставляет искать, что заменили.
        let hadOne = app.tlsCertificates.current() != nil
        do {
            let issued = try app.tlsCertificates.issue()
            // Работающий прокси держит прежнюю идентичность, пока его
            // не перезапустят: сказать об этом важнее, чем промолчать.
            if app.proxy.state.isRunning {
                app.proxy.stop()
                do {
                    try app.startProxy()
                } catch {
                    // Сертификат уже новый, а прокси не поднялся: сказать
                    // об этом важнее, чем отрапортовать об успехе выпуска.
                    app.refreshSecuritySnapshot()
                    errorMessage = String(localized: "Сертификат выпущен, но прокси не запустился: \(app.describe(error))")
                    return
                }
            }
            app.refreshSecuritySnapshot()
            statusMessage = hadOne
                ? String(localized: "Сертификат выпущен заново. Новый отпечаток: \(issued.fingerprint.prefix(23))… — передайте его клиентам.")
                : String(localized: "Сертификат выпущен. Отпечаток: \(issued.fingerprint.prefix(23))…")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    /// Сохраняет сертификат в файл: клиенту нужен либо он, либо отпечаток.
    func exportCertificate(_ app: AppEnvironment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "chromadb-manager.pem"
        panel.message = String(localized: "Этот файл передаётся клиенту, чтобы он доверял прокси. Секрета в нём нет.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.tlsCertificates.export(to: url)
            statusMessage = String(localized: "Сертификат сохранён: \(url.lastPathComponent)")
        } catch {
            errorMessage = app.describe(error)
        }
    }

    /// Пример для того, кто будет подключаться. Показывается с настоящим
    /// портом и настоящей схемой — набирать его руками по памяти неоткуда.
    func connectionExample(app: AppEnvironment) -> String {
        let port = app.settings.configuration.proxyPort.plainDigits
        guard app.settings.configuration.proxyUsesTLS else {
            return "curl http://127.0.0.1:\(port)/api/v2/heartbeat -H \"X-Chroma-Token: КЛЮЧ\""
        }
        return "curl --cacert chromadb-manager.pem https://127.0.0.1:\(port)/api/v2/heartbeat -H \"X-Chroma-Token: КЛЮЧ\""
    }

    // MARK: - Connection details

    /// The address an external client should point at. Shown because telling
    /// someone «прокси открыт наружу» without saying where is not an answer.
    func externalAddresses(port: Int) -> [String] {
        LocalNetwork.addresses().map { "\($0):\(port.plainDigits)" }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = String(localized: "Скопировано: \(text)")
    }
}
