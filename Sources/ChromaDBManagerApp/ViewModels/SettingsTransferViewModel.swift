import Foundation
import AppKit
import ChromaCore

/// one file with everything except secrets, and an import that says what it
/// would change before it changes it.
@MainActor
final class SettingsTransferViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    /// The file has been read and understood; nothing is written until the user
    /// confirms this plan (rule 2 of Приложение 5).
    @Published var pending: PendingImport?

    struct PendingImport: Identifiable {
        let id = UUID()
        let fileName: String
        let bundle: SettingsBundle
        let plan: SettingsImportPlan
        var includePreferences: Bool
    }

    // MARK: - Export

    func export(_ app: AppEnvironment) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт настроек приложения")
        panel.nameFieldStringValue = "chromadbmanager-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = SettingsTransfer.export(
            configuration: app.settings.configuration,
            schemas: app.schemaStore.schemas,
            savedFilters: app.savedFilters.all(),
            appVersion: Self.appVersion
        )
        do {
            try SettingsTransfer.encode(bundle).write(to: url, options: .atomic)
            statusMessage = String(localized: "Настройки выгружены в \(url.lastPathComponent). Токены и ключи в файл не попали — на другой машине их нужно ввести заново.")
            app.log.record(
                .success, "Настройки",
                "Экспорт настроек: профилей \(bundle.serverProfiles.count.plainDigits), источников \(bundle.sources.count.plainDigits), схем \(bundle.schemas.count.plainDigits), фильтров \(bundle.savedFilters.count.plainDigits), клиентов \(bundle.clients.count.plainDigits) — без секретов"
            )
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Настройки")
        }
    }

    // MARK: - Import

    /// Reads and explains. Deliberately two steps: an import that merged on the
    /// spot would be the one operation in the app that changes everything at
    /// once without showing what it touched.
    func chooseFileForImport(_ app: AppEnvironment) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Импорт настроек приложения")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bundle = try SettingsTransfer.decode(try Data(contentsOf: url))
            let plan = SettingsTransfer.plan(
                for: bundle,
                configuration: app.settings.configuration,
                schemas: app.schemaStore.schemas,
                savedFilters: app.savedFilters.all(),
                hasToken: { app.keychain.hasToken(for: $0.keychainAccount) }
            )
            pending = PendingImport(
                fileName: url.lastPathComponent,
                bundle: bundle,
                plan: plan,
                includePreferences: true
            )
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Настройки")
        }
    }

    func cancelImport() {
        pending = nil
    }

    func confirmImport(_ app: AppEnvironment) {
        guard let pending else { return }
        self.pending = nil

        var configuration = app.settings.configuration
        var schemas = app.schemaStore.schemas
        var filters = app.savedFilters.all()

        SettingsTransfer.apply(
            pending.bundle,
            to: &configuration,
            schemas: &schemas,
            savedFilters: &filters,
            includePreferences: pending.includePreferences
        )

        app.settings.configuration = configuration
        app.schemaStore.replaceAll(schemas)
        app.savedFilters.replaceAll(filters)

        let plan = pending.plan
        statusMessage = String(localized: "Импортировано из \(pending.fileName): профилей \(plan.profiles.total.plainDigits), источников \(plan.sources.total.plainDigits), схем \(plan.schemas.total.plainDigits), фильтров \(plan.filters.total.plainDigits), клиентов \(plan.clients.total.plainDigits).")
        app.log.record(
            .success, "Настройки",
            "Импорт настроек из «\(pending.fileName)»: добавлено и заменено — профилей \(plan.profiles.total.plainDigits), источников \(plan.sources.total.plainDigits), схем \(plan.schemas.total.plainDigits), фильтров \(plan.filters.total.plainDigits), клиентов \(plan.clients.total.plainDigits); общие настройки \(pending.includePreferences ? "применены" : "не тронуты")"
        )
        if !plan.clientsNeedingKey.isEmpty {
            app.log.record(
                .warning, "Настройки",
                "Импортированным клиентам ключи не переносятся — выпустите новые: \(plan.clientsNeedingKey.joined(separator: ", "))"
            )
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
