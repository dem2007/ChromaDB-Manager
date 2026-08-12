import SwiftUI
import ChromaCore

/// Содержимое значка в строке меню.
///
/// Окном, а не обычным меню: в обычное меню нельзя положить поле ввода,
/// а быстрый поиск без поля ввода — это не быстрый поиск.
struct MenuBarView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var queueMirror: QueueMirror
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var search: QuickSearchViewModel
    /// Открыть главное окно и, если надо, окно просмотра.
    let openMainWindow: (ExternalRequest?) -> Void
    let openViewerWindow: () -> Void

    private var summary: MenuBarSummary {
        MenuBarSummary(
            tasks: queueMirror.tasks,
            paused: settings.configuration.automaticSyncPaused,
            lastSync: app.lastSyncSummary
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            Divider()
            quickSearch
            Divider()
            footer
        }
        .padding(12)
        // Высота задана жёстко, а не по содержимому: всплывающее окно
        // `MenuBarExtra` защёлкивает размер при первом показе и под
        // появившиеся результаты не растёт — они оказывались за краем
        // и выглядели как «поиск ничего не нашёл». Проверено в окне.
        .frame(width: 400, height: 430, alignment: .top)
    }

    // MARK: - Состояние

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: summary.symbol)
                Text(summary.headline).font(Theme.Font.caption.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
            }
            if let queue = summary.queueLine {
                Text(queue).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            if let paused = summary.pausedLine {
                Text(paused).font(Theme.Font.caption).foregroundStyle(.orange)
            }
            if let sync = summary.lastSync {
                Text(sync).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            // Глобальная пауза (8.4) — прямо здесь: ради неё в строку меню
            // и заглядывают, когда LM Studio занята чем-то другим.
            Toggle(isOn: Binding(
                get: { settings.configuration.automaticSyncPaused },
                set: { settings.configuration.automaticSyncPaused = $0 }
            )) {
                Text("Пауза автоматической синхронизации").font(Theme.Font.caption)
            }
            .toggleStyle(.switch).controlSize(.mini)
            .padding(.top, 2)
        }
    }

    // MARK: - Быстрый поиск

    private var quickSearch: some View {
        // Тот же вид, что в панели по горячей клавише: две реализации
        // быстрого поиска разошлись бы через месяц.
        QuickSearchView(search: search, openDocument: openViewerWindow)
    }

    // MARK: - Низ

    private var footer: some View {
        HStack {
            Button("Открыть окно") {
                openMainWindow(search.hits.isEmpty ? nil : .search(
                    collection: settings.configuration.menuBar.quickSearchCollection,
                    text: search.text
                ))
            }
            .controlSize(.small)
            Spacer()
            Button("Выйти") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}
