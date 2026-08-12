import SwiftUI
import AppKit
import ChromaCore

/// Быстрый поиск: поле, список результатов и переход к исходнику.
///
/// Один вид на два места — на всплывающее окно значка в строке меню и на
/// панель по горячей клавише. Разные реализации разошлись бы через месяц.
struct QuickSearchView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var search: QuickSearchViewModel
    /// Открыть исходник результата. Снаружи, потому что из строки меню это
    /// отдельное окно, а из панели — она же.
    let openDocument: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { settings.configuration.menuBar.quickSearchCollection ?? "" },
                set: { search.choose($0.isEmpty ? nil : $0, app: app) }
            )) {
                Text("коллекция не выбрана").tag("")
                ForEach(search.collections, id: \.name) { collection in
                    Text(collection.name).tag(collection.name)
                }
            }
            .labelsHidden().controlSize(.small)

            HStack(spacing: 6) {
                TextField("Что искать", text: $search.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search.search(app) } }
                if search.isSearching { ProgressView().controlSize(.small) }
            }

            if let problem = search.problem {
                Text(problem).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if search.hits.isEmpty {
                // Место под результаты занято сразу: у всплывающего окна
                // строки меню высота фиксированная, и без распорки список
                // прыгал бы снизу вверх при каждом поиске.
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(search.hits) { hit in
                            resultRow(hit)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .task { await search.reloadCollections(app) }
    }

    private func resultRow(_ hit: RetrievalHit) -> some View {
        Button {
            // H1 прямо отсюда: смотреть исходник — то, ради чего результат
            // и открывают.
            app.documentViewer.open(
                chunk: hit.document ?? "",
                metadata: hit.metadata,
                title: hit.id,
                app: app
            )
            openDocument()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.document ?? "")
                    .font(Theme.Font.caption).lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let name = DocumentLocator.reference(metadata: hit.metadata).fileName {
                    Text(name).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Показать фрагмент в исходном документе"))
    }
}

/// Плавающая панель быстрого поиска по горячей клавише.
///
/// На AppKit, а не сценой SwiftUI: панель обязана открываться и тогда, когда
/// ни одного окна нет, — иначе горячая клавиша в режиме «только строка меню»
/// не делала бы ничего. Программно открыть всплывающее окно `MenuBarExtra`
/// SwiftUI не позволяет, поэтому вызов по клавише — это она.
@MainActor
final class QuickSearchPanelController {
    private var panel: NSPanel?
    private let app: AppEnvironment
    private let search: QuickSearchViewModel
    private let openDocument: () -> Void

    init(app: AppEnvironment, search: QuickSearchViewModel, openDocument: @escaping () -> Void) {
        self.app = app
        self.search = search
        self.openDocument = openDocument
    }

    /// Повторное нажатие клавиши закрывает панель: сочетание одно, и
    /// «вызвать» без «убрать» заставляло бы тянуться к мыши.
    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Панель показывается поверх чужих окон, но приложение при этом не
        // выходит на передний план целиком: человек вызвал поиск, а не
        // переключение задач.
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let view = QuickSearchView(search: search, openDocument: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.openDocument()
        })
        .chromaEnvironment(app)
        .padding(14)
        // Высота задана сразу: панель по клавише открывается ради
        // результатов, и показывать их в щели высотой в две строки
        // бессмысленно.
        .frame(width: 460, height: 420, alignment: .top)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = String(localized: "Быстрый поиск")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }
}
