import SwiftUI
import AppKit
import Combine
import ChromaCore

struct ChromaDBManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Общий экземпляр, а не новый на каждое построение сцены.
    //
    // Ссылкой, а не `@StateObject`: со `@StateObject` любое изменение
    // окружения пересчитывало все сцены, в том числе значок строки меню, и
    // SwiftUI заново ставил ему картинку — посреди раскладки главного окна
    // AppKit на это бросает исключение, приложение падало (отчёты 29 и 30
    // сентября 2026). Окна подписываются на окружение сами, через
    // `chromaEnvironment`; сцене следить за ним незачем.
    private let app = AppEnvironment.shared
    private let quickSearch = Self.quickSearchModel
    static let quickSearchModel = QuickSearchViewModel()

    var body: some Scene {
        // Одиночной сценой, а не группой: у приложения всегда одно главное
        // окно, а `WindowGroup` с идентификатором восстанавливал их пачкой —
        // на один запуск открывалось семь одинаковых. Проверено в окне.
        Window(String(localized: "ChromaDB Manager"), id: Self.mainWindowID) {
            RootView()
                .chromaEnvironment(app)
                .modifier(MenuBarSupport(
                    app: app, quickSearch: quickSearch, delegate: appDelegate
                ))
        }
        // Тулбар системный, заголовок раздела — в нём (`navigationTitle`).
        // Минимальный размер окна задаёт корень `RootView` (900×560).
        .windowToolbarStyle(.unified)
        .defaultSize(MainWindowSize.initial)
        .commands {
            MainWindowCommands()
        }

        // Окно «Настройки» (⌘) — настройки самого приложения.
        Settings {
            SettingsWindow()
                .chromaEnvironment(app)
        }

        // Отдельное окно просмотра исходника — его открывает быстрый
        // поиск из строки меню. Листом это показать не на чем: главное окно
        // в этот момент может быть закрыто.
        Window(String(localized: "Исходный документ"), id: Self.viewerWindowID) {
            DocumentViewerSheet(model: app.documentViewer)
                .chromaEnvironment(app)
        }
        .defaultSize(MainWindowSize.viewer)

        // Значок в строке меню — `StatusItemController` (AppKit), не
        // `MenuBarExtra`: тот падал, обновляя кнопку значка посреди
        // раскладки главного окна. Заводит его делегат при запуске.
    }

    static let mainWindowID = "main"
    static let viewerWindowID = "viewer"
}

/// Keeps the app a regular windowed app when launched from the command line
/// (`swift run`), and makes sure a server we started is not left behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Запустить приложение заново, когда этот процесс выйдет.
    ///
    /// Статическое, а не через `NSApp.delegate`: при `NSApplicationDelegateAdaptor`
    /// делегат приложения — обёртка SwiftUI, и приведение к этому классу
    /// ненадёжно. Снимается, если выход отменили.
    @MainActor static var relaunchOnExit = false

    /// Окружение приложения — общее, а не проведённое сюда из `.onAppear`.
    ///
    /// Пока ссылку ставил вид, всё, что AppKit приносит до первого окна,
    /// терялось: папка, брошенная на значок незапущенного приложения,
    /// приходит в `application(_:open:)` раньше любого `.onAppear`, и
    /// `guard let environment` её выбрасывал. Так же — текст из «Служб»,
    /// которые запускают приложение.
    @MainActor var environment: AppEnvironment? { AppEnvironment.shared }
    var quickSearch: QuickSearchViewModel?
    /// Как открыть окно просмотра исходника. Ставится сценой: у делегата
    /// нет доступа к `openWindow`, а угадывать окно по заголовку — способ
    /// сломаться на первом же переводе.
    var openViewer: (() -> Void)?
    /// Как создать главное окно, когда ни одного нет.
    var openMain: (() -> Void)?
    /// `openViewer` и `openMain` дало главное окно, а не окно значка.
    var hasMainWindowActions = false

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
    private var statusItem: StatusItemController?
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
    func openViewerWindow() {
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
        // Значок в строке меню — с самого запуска, до первого окна.
        quickSearch = quickSearch ?? ChromaDBManagerApp.quickSearchModel
        if let environment, let quickSearch {
            statusItem = StatusItemController(app: environment, quickSearch: quickSearch, delegate: self)
            // Клавиша и мост MCP — с запуска, а не с первого окна: приложение,
            // живущее в строке меню, могло запуститься вовсе без окна.
            // Повторные вызовы из окна безвредны. Следующим ходом, как и
            // размер окна: `startMenuBarSupport` выставляет политику Dock по
            // тому, видно ли окно, а сейчас его ещё нет — значок ушёл бы из
            // Dock на старте.
            DispatchQueue.main.async {
                self.startMenuBarSupport()
                environment.mcp.start(environment)
            }
        }
    }

    /// `Scene.defaultSize` is treated as a hint and macOS ignores it here, so
    /// the very first window is sized explicitly — wide enough for the
    /// collections screen. Afterwards macOS restores whatever size the user
    /// left the window at, and this never runs again.
    private func sizeInitialWindowIfNeeded() {
        let key = "hasSizedInitialWindow"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }

        let preferred = MainWindowSize.initial
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
    ///
    /// Only in a debug build: `#filePath` is the absolute path on the build
    /// machine, and a release binary would carry the builder's home folder.
    private func applyDockIconWhenUnbundled() {
        #if DEBUG
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
        #endif
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
        guard alert.runModal() == .alertFirstButtonReturn else {
            // Выход отменили — и перезапуск вместе с ним: иначе приложение
            // перезапустилось бы, когда человек выйдет когда-нибудь потом.
            Self.relaunchOnExit = false
            return .terminateCancel
        }

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
        if Self.relaunchOnExit { Self.scheduleRelaunch() }
    }

    /// Новый экземпляр — **после** выхода этого, а не до.
    ///
    /// Прежде новая копия запускалась первой, а выход, о котором спрашивают
    /// при идущей индексации, человек мог отменить: оставались две копии
    /// с одними настройками, прокси и сервером. Здесь выход уже решён,
    /// а запуск ждёт, пока этот процесс действительно завершится: иначе
    /// `open` просто вернул бы на передний план нас же. Путь передаётся
    /// аргументом, а не вставляется в строку команды.
    static func scheduleRelaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath,
        ]
        try? waiter.run()
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
