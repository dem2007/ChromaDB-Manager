import SwiftUI
import ChromaCore

/// Состояние подключения внизу боковой панели.
///
/// Видно с любого раздела — поэтому здесь же и то, что нельзя пропустить,
/// где бы человек ни был: подключение только для чтения, несохраняемые
/// настройки и идущая автоматическая работа ( — автоматика не бывает
/// невидимой). Время работы сервера и режим — на «Обзоре», здесь их нет.
struct ConnectionStatusFooter: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var collectionsModel: CollectionsViewModel
    @ObservedObject var autoSync: AutoSyncCoordinator

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                // Коротко — что подключено; версия и адрес — в подсказке
                // (v3): полная строка в сайдбар не помещалась.
                StatusLabel(state, shortTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(app.connection.title)
                Spacer()
                if case .connecting = app.connection {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            await app.reconnect()
                            await collectionsModel.refresh(app)
                        }
                    } label: {
                        Label(String(localized: "Переподключиться"), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Переподключиться к ChromaDB"))
                }
            }

            if app.connection.isReadOnly {
                StatusLabel(.warning, String(localized: "только чтение"))
                    .help(String(localized: "Подключение открыто только для чтения: запись, импорт и синхронизация отклоняются."))
            }

            if let problem = settings.persistenceProblem {
                StatusLabel(.error, String(localized: "настройки не сохраняются"))
                    .help(problem)
            }

            if let activity = autoSync.activity {
                HStack {
                    ProgressView()
                    Text(activity)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(activity)
                }
            } else if settings.configuration.automaticSyncPaused,
                      settings.configuration.dataSources.contains(where: { $0.triggers.isAnyEnabled }) {
                StatusLabel(.warning, String(localized: "автоиндексация на паузе"))
            }
        }
        .controlSize(.small)
        .font(.callout)
        .padding()
    }

    private var shortTitle: String {
        switch app.connection {
        case .connected(let address, _, let isLocal, _):
            return isLocal ? String(localized: "Локальная база") : address
        case .failed:
            return String(localized: "Ошибка подключения")
        default:
            return app.connection.title
        }
    }

    private var state: StatusLabel.State {
        switch app.connection {
        case .connected: return .ok
        case .connecting: return .warning
        case .failed: return .error
        case .disconnected: return .off
        }
    }
}
