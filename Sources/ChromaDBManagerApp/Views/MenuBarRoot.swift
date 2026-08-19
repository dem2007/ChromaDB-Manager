import SwiftUI
import ChromaCore

/// Содержимое значка в строке меню вместе с открытием окон.
///
/// Отдельным видом, а не прямо в сцене приложения: `openWindow` — значение
/// окружения **вида**. В теле `App` оно не работает, и главное окно тогда не
/// создаётся вовсе — проверено в окне 6 августа 2026.
struct MenuBarRoot: View {
    @ObservedObject var app: AppEnvironment
    @ObservedObject var quickSearch: QuickSearchViewModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(
            search: quickSearch,
            mcp: app.mcp,
            openMainWindow: { request in
                app.pendingRequest = request
                delegate.showMainWindow()
            },
            openViewerWindow: {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: ChromaDBManagerApp.viewerWindowID)
            }
        )
        // Всё окружение целиком, а не «нужное»: меню читает и очередь,
        // и настройки, и состояние приложения, а забытый объект здесь —
        // не пустой экран, а падение при клике по значку.
        .chromaEnvironment(app)
        .modifier(MenuBarSupport(app: app, quickSearch: quickSearch, delegate: delegate))
    }
}

/// Сообщает делегату, чем открывать окна, и поднимает горячую клавишу.
///
/// Ставится и на главное окно, и на меню: строка меню живёт и тогда, когда
/// окно не открывали ни разу, а окно — когда значок в меню выключен.
struct MenuBarSupport: ViewModifier {
    let app: AppEnvironment
    let quickSearch: QuickSearchViewModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.environment = app
            delegate.quickSearch = quickSearch
            delegate.openViewer = { openWindow(id: ChromaDBManagerApp.viewerWindowID) }
            delegate.openMain = { openWindow(id: ChromaDBManagerApp.mainWindowID) }
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
