import AppKit
import Combine
import SwiftUI
import ChromaCore

/// Значок в строке меню и его окно — на AppKit, а не `MenuBarExtra`.
///
/// `MenuBarExtra` ставил картинку кнопке значка при обновлениях сцены, и
/// когда это совпадало с раскладкой главного окна (синхронизация, смена
/// размера окна), AppKit бросал исключение из `NSStatusBarButton.setImage` —
/// приложение падало (отчёты 29 и 30 сентября 2026). Постоянная картинка и
/// сцена, не следящая за окружением, падение не убрали: SwiftUI обновлял
/// кнопку и без этого. Здесь картинка ставится один раз, при создании
/// значка, и больше её никто не трогает.
///
/// Содержимое окна — тот же `MenuBarView` на SwiftUI.
@MainActor
final class StatusItemController: NSObject {
    private let app: AppEnvironment
    private let quickSearch: QuickSearchViewModel
    private weak var delegate: AppDelegate?
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var subscription: AnyCancellable?

    init(app: AppEnvironment, quickSearch: QuickSearchViewModel, delegate: AppDelegate) {
        self.app = app
        self.quickSearch = quickSearch
        self.delegate = delegate
        super.init()
        popover.behavior = .transient
        popover.animates = true
        // Показывать ли значок — настройка; значок появляется и исчезает
        // вслед за ней сразу, а не до следующего запуска.
        subscription = app.settings.$configuration
            .map(\.menuBar.showsIcon)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shown in self?.setShown(shown) }
    }

    private func setShown(_ shown: Bool) {
        if shown, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "ChromaDB Manager")
                button.target = self
                button.action = #selector(toggle(_:))
            }
            self.item = item
        } else if !shown, let item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Содержимое строится при каждом открытии: закрытое окно значка не
        // держит живой граф видов и не пересчитывается от тиков очереди.
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private var rootView: some View {
        let app = self.app
        return MenuBarView(
            search: quickSearch,
            mcp: app.mcp,
            openMainWindow: { [weak self] request in
                app.pendingRequest = request
                self?.popover.performClose(nil)
                self?.delegate?.showMainWindow()
            },
            openViewerWindow: { [weak self] in
                self?.popover.performClose(nil)
                self?.delegate?.openViewerWindow()
            }
        )
        .menuBarSupport(app: app, quickSearch: quickSearch, delegate: delegate)
        // Всё окружение целиком: забытый объект здесь — не пустой экран, а
        // падение при щелчке по значку.
        .chromaEnvironment(app)
    }
}

private extension View {
    /// Чем открывать окна, если главного ещё не было: приложение могло
    /// запуститься прямо в строку меню. Раньше это делал `MenuBarExtra`.
    @ViewBuilder
    func menuBarSupport(app: AppEnvironment, quickSearch: QuickSearchViewModel, delegate: AppDelegate?) -> some View {
        if let delegate {
            modifier(MenuBarSupport(app: app, quickSearch: quickSearch, delegate: delegate, isFallback: true))
        } else {
            self
        }
    }
}
