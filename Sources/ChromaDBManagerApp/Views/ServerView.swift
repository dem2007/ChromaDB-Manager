import SwiftUI
import ChromaCore

/// Spec: start / stop, status, PID, uptime, address, the process's own
/// output in a panel of its own, and an optional start on launch.
struct ServerView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var processManager: ChromaProcessManager
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var proxy: ProxyServer
    @ObservedObject var model: ServerViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let error = model.errorMessage {
                    MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
                }
                if let status = model.statusMessage {
                    MessageBanner(kind: .success, text: status) { model.statusMessage = nil }
                }
                // Осталось ровно то, ради чего эту вкладку открывают:
                // управление процессом. Состояние переехало на «Состояние»,
                // прокси — в «Безопасность», журнал — в «Логи», чужие
                // процессы — в «Окружение».
                controlCard
                launchCard
            }
            .padding(.top, 8)
            .pageContentPadding()
        }
        .task { model.refreshRuns(app) }
    }

    // MARK: - Управление процессом

    private var controlCard: some View {
        SectionCard(
            title: String(localized: "Процесс"),
            subtitle: String(localized: "Запуск и остановка сервера, который держит базу."),
            help: String(localized: "Приложение запускает chroma как обычную программу и следит за ней, пока открыто. Остановка не трогает данные: база — это папка на диске, сервер лишь даёт к ней доступ по сети.")
        ) {
            HStack(spacing: 10) {
                StatusDot(state: processManager.isRunning ? .ok : .unknown)
                Text(processManager.state.title).font(Theme.Font.body)
                Spacer(minLength: 8)
                if model.isBusy { ProgressView().controlSize(.small) }
                serverButtons
            }
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder
    private var serverButtons: some View {
        Group {
            if processManager.isRunning {
                Button(String(localized: "Перезапустить")) {
                    Task { await model.restart(app, collectionsModel: collectionsModel) }
                }
                .buttonStyle(.chromaNormal)
                // Остановка сервера — из тех строк, что не прячутся: пока он
                // стоит, недоступны и коллекции, и поиск, и агенты.
                Button(String(localized: "Остановить")) {
                    Task { await model.stop(app) }
                }
                .buttonStyle(.chromaDanger)
            } else {
                Button(String(localized: "Запустить")) {
                    Task { await model.start(app, collectionsModel: collectionsModel) }
                }
                .buttonStyle(.chromaPrimary)
            }
        }
    }

    // MARK: - Launch options

    private var launchCard: some View {
        SectionCard(title: String(localized: "Запуск")) {
            Toggle(
                String(localized: "Запускать сервер при старте приложения"),
                isOn: $settings.configuration.autoStartServerOnLaunch
            )
            Text(settings.configuration.autoStartServerOnLaunch
                 ? String(localized: "При открытии приложение само подключится к базе — как раньше.")
                 : String(localized: "Приложение откроется без подключения; сервер запускается кнопкой выше."))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.captionText)
        }
    }

    // MARK: - Orphans

    /// A server left running by a crashed session keeps holding the database.
}
