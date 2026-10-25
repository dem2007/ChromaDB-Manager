import SwiftUI
import ChromaCore

/// Сообщает делегату, чем открывать окна, и поднимает горячую клавишу.
///
/// Ставится и на главное окно, и на меню: строка меню живёт и тогда, когда
/// окно не открывали ни разу, а окно — когда значок в меню выключен.
struct MenuBarSupport: ViewModifier {
    let app: AppEnvironment
    let quickSearch: QuickSearchViewModel
    let delegate: AppDelegate
    /// Окно значка — запасной источник `openWindow`: оно не перебивает тот,
    /// что дало главное окно, а только подменяет его, пока главного окна
    /// не было (приложение запущено без окна). Обновляется при каждом
    /// открытии: окно значка строится заново, прежнее уже закрыто.
    var isFallback = false
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.quickSearch = quickSearch
            if !isFallback || !delegate.hasMainWindowActions {
                delegate.openViewer = { openWindow(id: ChromaDBManagerApp.viewerWindowID) }
                delegate.openMain = { openWindow(id: ChromaDBManagerApp.mainWindowID) }
                if !isFallback { delegate.hasMainWindowActions = true }
            }
            delegate.startMenuBarSupport()
            // Сокет MCP поднимается вместе с приложением, а не с окном
            //: агент подключается к запущенному приложению, и
            // закрытое окно — не повод рвать мост, если приложение осталось
            // в строке меню. Это не сеть: файл сокета лежит в каталоге
            // пользователя, и без зарегистрированного ключа ни один
            // инструмент ничего не отдаёт. Повторный вызов безвреден —
            // `start` выходит сам, если уже слушает.
            app.mcp.start(app)
        }
    }
}
