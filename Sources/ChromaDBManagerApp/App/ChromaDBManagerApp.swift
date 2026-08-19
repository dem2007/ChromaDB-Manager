import SwiftUI
import AppKit
import Combine
import ChromaCore

struct ChromaDBManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Общий экземпляр, а не новый на каждое построение сцены:
    // автозамыкание `@StateObject` SwiftUI зовёт по многу раз, отбрасывая
    // лишние объекты уже после того, как их `init` открыл кеш и прочитал
    // журнал задач.
    @StateObject private var app = AppEnvironment.shared
    @StateObject private var quickSearch = QuickSearchViewModel()

    var body: some Scene {
        // Одиночной сценой, а не группой: у приложения всегда одно главное
        // окно, а `WindowGroup` с идентификатором восстанавливал их пачкой —
        // на один запуск открывалось семь одинаковых. Проверено в окне.
        Window(String(localized: "ChromaDB Manager"), id: Self.mainWindowID) {
            RootView()
                .chromaEnvironment(app)
                .frame(minWidth: 900, minHeight: 620)
                .modifier(MenuBarSupport(
                    app: app, quickSearch: quickSearch, delegate: appDelegate
                ))
        }
        // Заголовок окна прячется, а кнопки закрытия, сворачивания и
        // разворачивания остаются: они принадлежат окну, а не тулбару.
        // Скрытие самого тулбара (`.toolbar(.hidden, for: .windowToolbar)`)
        // забирало и их, и двойной клик по титульной полосе.
        .windowToolbarStyle(.unifiedCompact)
        // Opens wide enough for the collections screen without resizing.
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Отдельное окно просмотра исходника — его открывает быстрый
        // поиск из строки меню. Листом это показать не на чем: главное окно
        // в этот момент может быть закрыто.
        Window(String(localized: "Исходный документ"), id: Self.viewerWindowID) {
            DocumentViewerSheet(model: app.documentViewer)
                .chromaEnvironment(app)
        }
        .defaultSize(width: 900, height: 760)

        // Значок показывается или не показывается — оба варианта
        // доступны, навязывать «жизнь в строке меню» нельзя.
        MenuBarExtra(
            isInserted: Binding(
                get: { app.settings.configuration.menuBar.showsIcon },
                set: { app.settings.configuration.menuBar.showsIcon = $0 }
            )
        ) {
            MenuBarRoot(app: app, quickSearch: quickSearch, delegate: appDelegate)
        } label: {
            Image(systemName: MenuBarSummary(
                tasks: app.queueMirror.tasks,
                paused: app.settings.configuration.automaticSyncPaused,
                lastSync: app.lastSyncSummary
            ).symbol)
        }
        .menuBarExtraStyle(.window)
    }

    static let mainWindowID = "main"
    static let viewerWindowID = "viewer"
}

/// Keeps the app a regular windowed app when launched from the command line
/// (`swift run`), and makes sure a server we started is not left behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var environment: AppEnvironment?
    var quickSearch: QuickSearchViewModel?
    /// Как открыть окно просмотра исходника. Ставится сценой: у делегата
    /// нет доступа к `openWindow`, а угадывать окно по заголовку — способ
    /// сломаться на первом же переводе.
    var openViewer: (() -> Void)?
    /// Как создать главное окно, когда ни одного нет.
    var openMain: (() -> Void)?

    /// Показывает главное окно: уже открытое выносит вперёд и новое
    /// заводит только если открытых нет.
    ///
    /// `openWindow` у `WindowGroup` **каждый раз делает новое окно**, и за
    /// сеанс их набирался десяток — на следующем запуске macOS восстанавливал
    /// все. Проверено в окне: семь одинаковых окон на один запуск.
    @MainActor
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { window in
            window.isVisible && window.canBecomeMain
                && (window.identifier?.rawValue.hasPrefix(ChromaDBManagerApp.mainWindowID) ?? false)
        }
        if let main {
            main.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    /// Глобальная клавиша и панель поиска живут здесь, а не в сцене:
    /// они обязаны работать и тогда, когда ни одного окна нет.
    private var hotKey: GlobalHotKey?
    private var panel: QuickSearchPanelController?
    private var settingsObserver: AnyCancellable?

    @MainActor
    func startMenuBarSupport() {
        guard let environment, let quickSearch, hotKey == nil else {
            // Настройки могли поменяться между двумя вызовами — приводим
            // регистрацию к ним в любом случае.
            applyHotKeyPreferences()
            return
        }
        let controller = QuickSearchPanelController(
            app: environment, search: quickSearch,
            openDocument: { [weak self] in self?.openViewerWindow() }
        )
        panel = controller
        hotKey = GlobalHotKey(log: environment.logHandler) { controller.toggle() }
        applyHotKeyPreferences()
        // Клавиша меняется в настройках — регистрация обязана следовать за
        // ними сразу, а не до следующего запуска.
        settingsObserver = environment.settings.$configuration
            .receive(on: RunLoop.main)
            .sink { [weak self] configuration in
                self?.hotKey?.apply(configuration.menuBar)
                self?.applyDockPolicy(configuration.menuBar)
            }
    }

    @MainActor
    private func applyHotKeyPreferences() {
        guard let environment else { return }
        hotKey?.apply(environment.settings.configuration.menuBar)
        applyDockPolicy(environment.settings.configuration.menuBar)
    }

    /// Значок в Dock убирается только вместе с открытым окном и только если
    /// значок в строке меню показан: приложение без обоих было бы
    /// недостижимо ничем, кроме принудительного завершения.
    @MainActor
    private func applyDockPolicy(_ preferences: MenuBarPreferences) {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let mayHide = preferences.keepsRunningWithoutWindow && preferences.showsIcon
        let wanted: NSApplication.ActivationPolicy = hasWindow || !mayHide ? .regular : .accessory
        // Только при настоящей смене. Повторный `.regular` у и так обычного
        // приложения — не пустая операция: SwiftUI отвечает на неё новым
        // окном, а настройки при запуске публикуются несколько раз подряд.
        // Так на один запуск открывалось семь одинаковых окон — проверено.
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    /// Открывает окно просмотра исходника по требованию из строки меню.
    @MainActor
    private func openViewerWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openViewer?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // без этого пункты «Служб» в чужих приложениях не появятся.
        NSApp.servicesProvider = self
        applyDockIconWhenUnbundled()
        DispatchQueue.main.async { self.sizeInitialWindowIfNeeded() }
    }

    /// `Scene.defaultSize` is treated as a hint and macOS ignores it here, so
    /// the very first window is sized explicitly — wide enough for the
    /// collections screen. Afterwards macOS restores whatever size the user
    /// left the window at, and this never runs again.
    private func sizeInitialWindowIfNeeded() {
        let key = "hasSizedInitialWindow"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }

        let preferred = CGSize(width: 1180, height: 780)
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: preferred.width, height: preferred.height)
        window.setContentSize(CGSize(
            width: min(preferred.width, available.width - 40),
            height: min(preferred.height, available.height - 40)
        ))
        window.center()

        UserDefaults.standard.set(true, forKey: key)
    }

    /// Inside `ChromaDB Manager.app` the icon comes from `CFBundleIconFile`.
    /// A plain `swift run` binary has no bundle, so point the Dock at the icon
    /// in the source tree — a developer convenience, skipped in the shipped app.
    private func applyDockIconWhenUnbundled() {
        guard Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil else { return }

        let repositoryIcon = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App/
            .deletingLastPathComponent()   // ChromaDBManagerApp/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Resources/AppIcon.icns")

        if let image = NSImage(contentsOf: repositoryIcon) {
            NSApp.applicationIconImage = image
        }
    }

    /// По умолчанию закрытие окна закрывает приложение — так оно вело
    /// себя всегда, и «не закрывается по красной кнопке» воспринимается как
    /// поломка. Остаться в строке меню можно, но только по явной настройке
    /// и только пока значок там показан.
    /// Файлы и папки, брошенные на значок в Dock или открытые двойным
    /// щелчком. Приложение ничего не делает само — оно открывает окно
    /// и спрашивает, что с ними делать.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let environment else { return }
        showMainWindow()
        environment.pendingRequest = .dropped(urls: urls)
    }

    /// Пункт меню «Службы» для выделенного текста.
    ///
    /// Регистрируется в `Info.plist`; сюда система приносит то, что человек
    /// выделил в чужом приложении. Текст не добавляется молча — открывается
    /// форма с ним, где человек выбирает коллекцию и подтверждает.
    @MainActor
    @objc func addTextFromService(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            error.pointee = String(localized: "Выделенный текст пуст.") as NSString
            return
        }
        showMainWindow()
        environment?.pendingRequest = .addText(text)
    }

    /// Пункт «Служб» для файлов, выделенных в Finder.
    @MainActor
    @objc func addFilesFromService(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = String(localized: "Файлы не переданы.") as NSString
            return
        }
        showMainWindow()
        environment?.pendingRequest = .dropped(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let environment else { return true }
        let preferences = environment.settings.configuration.menuBar
        let stays = preferences.keepsRunningWithoutWindow && preferences.showsIcon
        if stays { NSApp.setActivationPolicy(.accessory) }
        return !stays
    }

    /// Quitting in the middle of an indexing run used to be a silent kill.
    /// Now it asks, and on «прервать» it cancels properly and waits for the
    /// operations to unwind — the sync journal is written on the way out, so
    /// the next launch can replay what was in flight.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment, !environment.longOperations.isEmpty else { return .terminateNow }

        let names = environment.longOperations.map(\.title).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = String(localized: "Идёт длительная операция")
        alert.informativeText = String(localized: "\(names). Прервать и выйти? Незавершённая работа будет продолжена при следующем запуске.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Прервать и выйти"))
        alert.addButton(withTitle: String(localized: "Не выходить"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        environment.cancelLongOperations()
        Task { @MainActor in
            // Cancellation is cooperative: give the tasks a moment to write
            // their journals rather than quitting the instant we asked.
            let deadline = Date().addingTimeInterval(5)
            while !environment.longOperations.isEmpty, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Servers this app started must not outlive it.
        ManagedProcessRegistry.shared.terminateAll()
    }
}

/// Запуск приложения из исполняемой цели.
///
/// Единственное публичное имя библиотеки. Сама сцена и всё, что она
/// собирает, остаются внутренними: тестам достаточно `@testable`, а наружу
/// торчать целому экранному слою незачем.
public enum ChromaDBManagerLauncher {
    public static func run() { ChromaDBManagerApp.main() }
}
