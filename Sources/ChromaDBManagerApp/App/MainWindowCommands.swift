import SwiftUI
import ChromaCore

/// Команда строки меню к главному окну.
enum MainWindowCommand {
    case newCollection
    case newSource
    case newClientKey
    case connect
    case disconnect
    case restartServer
    /// Спрашивает подтверждение: пока сервер стоит, недоступно всё.
    case stopServer
    case backUp
    case search
    case addDocuments
    case export
    case reembed
    case selectTab(Int)
}

/// Что из команд сейчас доступно — сравнимым значением.
///
/// Сравнимым нарочно: меню перестраивается только тогда, когда доступность
/// правда изменилась. Значение, пересоздаваемое на каждой перерисовке окна,
/// перестраивало меню каждый раз — и значок в строке меню обновлялся посреди
/// раскладки главного окна, а AppKit на это отвечает падением.
struct MainWindowCommandState: Equatable {
    var canConnect = false
    var canDisconnect = false
    var isServerRunning = false
    var canBackUp = false
    /// Коллекция выбрана на экране коллекций.
    var hasCollection = false
    var canSearch = false
    var canAddDocuments = false
    var canReembed = false
    /// Вкладки открытого раздела — для ⌘1…⌘5.
    var tabs: [String] = []
}

/// Мост между главным окном и строкой меню.
///
/// Один на окно и живёт, пока живёт окно: меню видит его через
/// `focusedSceneObject`, а действие идёт тем же путём, что кнопка на экране, —
/// второй реализации нет. Закрыто главное окно — объекта нет, пункты недоступны.
@MainActor
final class MainWindowCommandCenter: ObservableObject {
    @Published private(set) var state = MainWindowCommandState()
    var perform: (MainWindowCommand) -> Void = { _ in }

    func update(_ newState: MainWindowCommandState) {
        guard newState != state else { return }
        state = newState
    }
}

/// Строка меню приложения: «Файл», «База», «Коллекция», «Вид», «Справка».
struct MainWindowCommands: Commands {
    @FocusedObject private var center: MainWindowCommandCenter?

    private var state: MainWindowCommandState { center?.state ?? MainWindowCommandState() }

    private func run(_ command: MainWindowCommand) {
        center?.perform(command)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Новая коллекция…")) { run(.newCollection) }
                .keyboardShortcut("n")
                .disabled(!state.canDisconnect)
            Button(String(localized: "Новый источник…")) { run(.newSource) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(center == nil)
            Button(String(localized: "Новый ключ клиента…")) { run(.newClientKey) }
                .disabled(center == nil)
        }

        CommandMenu(String(localized: "База")) {
            Button(String(localized: "Подключиться")) { run(.connect) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!state.canConnect)
            Button(String(localized: "Отключиться")) { run(.disconnect) }
                .disabled(!state.canDisconnect)
            Divider()
            Button(String(localized: "Перезапустить сервер")) { run(.restartServer) }
                .keyboardShortcut("r")
                .disabled(!state.isServerRunning)
            Button(String(localized: "Остановить сервер…")) { run(.stopServer) }
                .disabled(!state.isServerRunning)
            Divider()
            Button(String(localized: "Сделать резервную копию")) { run(.backUp) }
                .disabled(!state.canBackUp)
        }

        CommandMenu(String(localized: "Коллекция")) {
            Button(String(localized: "Выполнить поиск")) { run(.search) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!state.canSearch)
            Button(String(localized: "Добавить документы…")) { run(.addDocuments) }
                .disabled(!state.canAddDocuments)
            Button(String(localized: "Экспортировать…")) { run(.export) }
                .disabled(!state.hasCollection)
            Divider()
            Button(String(localized: "Пересчитать векторы…")) { run(.reembed) }
                .disabled(!state.canReembed)
        }

        CommandGroup(after: .sidebar) {
            let tabs = Array(state.tabs.prefix(5))
            if !tabs.isEmpty {
                Divider()
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    Button(title) { run(.selectTab(index)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
        }

        SidebarCommands()
        ToolbarCommands()
        TextEditingCommands()

        CommandGroup(replacing: .help) {
            Button(String(localized: "Справка ChromaDB Manager")) {
                open("https://github.com/\(AppUpdateChecker.repository)#readme")
            }
            Button(String(localized: "Сообщить о проблеме…")) {
                open("https://github.com/\(AppUpdateChecker.repository)/issues/new")
            }
        }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
