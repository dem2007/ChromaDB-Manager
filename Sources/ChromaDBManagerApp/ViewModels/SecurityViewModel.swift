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
