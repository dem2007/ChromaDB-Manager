import SwiftUI
import AppKit
import ChromaCore

/// Экран «Обзор», вкладка «Состояние».
///
/// Первое, что видно при запуске, и единственный экран, отвечающий на вопрос
/// «что сейчас с базой». Раньше ответ собирался из трёх разделов: адрес — в
/// «Подключении», процесс — в «Сервере», прокси — в «Безопасности». Человек
/// узнавал, что что-то не работает, случайно.
///
/// Экран **только показывает**: ни одной операции он сам не начинает, кроме
/// тех, что и так есть на соседних вкладках. Каждая строка ведёт туда, где
/// это можно изменить.
struct OverviewView: View {
    @EnvironmentObject private var app: AppEnvironment
    /// Язык интерфейса живёт в `UserDefaults` системы, а не в конфигурации
    /// приложения: оттуда его читает загрузчик ресурсов.
    private let languages = InterfaceLanguageStore()
    @State private var needsRestart = false
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var processManager: ChromaProcessManager
    @ObservedObject var server: ServerViewModel
    @ObservedObject var collectionsModel: CollectionsViewModel
    @ObservedObject var environment: EnvironmentViewModel
    @ObservedObject var sources: SourcesViewModel
    /// Размер кэша векторов на плашке. Считает его та же модель, что и на
    /// экране «Модели», — число одно на приложение, а не два своих.
    @ObservedObject var embeddings: EmbeddingsViewModel
    /// Куда уйти, если человек решит закрыть находку. Экран не чинит сам —
    /// он показывает и провожает туда, где чинят.
    var go: (SidebarSection, Int?) -> Void = { _, _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                tiles
                nowCard
                // Процесс от прошлой сессии — рядом с фактами о сервере,
                // и до списка решений: он держит порт и базу, и это
                // не «стоит закрыть», а «вот прямо сейчас лишний сервер».
                // Карточки нет, когда таких процессов нет.
                ChromaProcessesCard(serverModel: server)
                decisionsCard
                languageCard
            }
            .padding(.top, 8)
            .pageContentPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await embeddings.refreshCacheStatistics(app) }
    }

    // MARK: - Язык интерфейса

    /// Выбор языка и честное «со следующего запуска».
    ///
    /// Язык бандла выбирается загрузчиком ресурсов **до** первой строки
    /// приложения, поэтому мгновенно переключить его нельзя: половина экрана
    /// осталась бы на прежнем языке, потому что тексты уже прочитаны. Экран
    /// говорит это прямо и предлагает перезапустить — а не делает вид, что
    /// поменял, и не перезапускает сам.
    private var languageCard: some View {
        SectionCard(
            title: String(localized: "Язык интерфейса"),
            subtitle: String(localized: "По умолчанию — как в системе. Выбор применится при следующем запуске: язык читается до того, как приложение покажет первое окно."),
            help: String(localized: "Английский перевод неполный: строки без перевода остаются русскими. Это видно сразу и ничего не ломает — приложение ищет текст по русской строке из кода.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                HStack(spacing: 10) {
                    Picker("", selection: Binding(
                        get: { languages.current },
                        set: { chosen in
                            needsRestart = languages.apply(chosen)
                            app.log.record(.info, "Интерфейс", "Язык интерфейса: \(chosen.title)")
                        }
                    )) {
                        ForEach(InterfaceLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)

                    if let running = InterfaceLanguageStore.running() {
                        Text("сейчас: \(running)")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    Spacer()
                }

                if needsRestart {
                    HStack(spacing: 10) {
                        Label(
                            String(localized: "Язык поменяется при следующем запуске."),
                            systemImage: "arrow.clockwise"
                        )
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                        Button(String(localized: "Перезапустить")) { restart() }
                            .buttonStyle(.chromaSecondary)
                        Spacer()
                    }
                }
            }
        }
    }

    /// Перезапуск: новый процесс запускается и только потом этот выходит.
    ///
    /// Порядок важен: выйти первым — значит оставить человека без окна, если
    /// запуск не удался.
    private func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Плашки

    /// Сколько всего — четырьмя числами, как в макете.
    ///
    /// Раньше внизу экрана лежала карточка «Что в базе» с шестью именами
    /// коллекций и хвостом «и ещё девять»: список коллекций уже есть на своём
    /// экране целиком, а здесь от него нужен был только счёт (правило 2).
    private var tiles: some View {
        HStack(spacing: 16) {
            StatTile(
                title: String(localized: "Коллекций"),
                value: collectionsModel.collections.count.formatted(),
                go: { go(.collections, nil) }
            )
            StatTile(
                title: String(localized: "Документов"),
                value: documentsValue,
                go: { go(.collections, nil) }
            )
            StatTile(
                title: String(localized: "Источников"),
                value: settings.configuration.dataSources.count.formatted(),
                go: { go(.sources, nil) }
            )
            StatTile(
                title: String(localized: "Кэш векторов"),
                value: embeddings.cacheStatistics?.sizeText ?? "—",
                go: { go(.models, nil) }
            )
        }
    }

    /// Пока число документов коллекции не пришло, оно `nil`, а не ноль:
    /// сложить их значит объявить пустыми те, о которых мы ещё не спросили.
    private var documentsValue: String {
        let known = collectionsModel.collections.compactMap(\.documentCount)
        guard !known.isEmpty else { return "—" }
        return known.reduce(0, +).formatted()
    }

    // MARK: - Сейчас

    private var nowCard: some View {
        SectionCard(
            title: String(localized: "Сейчас"),
            subtitle: String(localized: "Куда пишет приложение и что из этого работает."),
            help: String(localized: "Приложение само запускает процесс chroma и подключается к нему. Прокси — отдельный слой: только через него к базе ходят внешние клиенты. Сам ChromaDB всегда остаётся на 127.0.0.1.")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                statusRow(
                    title: String(localized: "Сервер ChromaDB"),
                    state: processManager.isRunning ? .ok : .unknown,
                    value: serverValue
                )
                statusRow(
                    title: String(localized: "Прокси"),
                    state: app.proxy.state.isRunning ? .ok : .unknown,
                    value: proxyValue
                )
                statusRow(
                    title: String(localized: "Адрес"),
                    state: app.connection.isConnected ? .ok : .missing,
                    value: addressValue,
                    isMonospaced: true
                )
                statusRow(
                    title: String(localized: "Папка базы"),
                    state: .ok,
                    value: databaseValue,
                    isMonospaced: true
                )
                statusRow(
                    title: String(localized: "Режим"),
                    state: .ok,
                    value: settings.configuration.mode.title
                )
                // Телеметрия показывается словами самого сервера, а не нашим
                // утверждением о нём: мы передаём то, что он сказал о себе
                // при запуске.
                //
                // Строка стоит всегда, даже когда сказать нечего.
                // Она появлялась вместе с ответом сервера — то есть через
                // секунду после запуска, — и карточка в этот момент
                // подрастала, уводя вниз всё, что под ней. «Сервер ещё не
                // отвечал» — такой же ответ, как остальные, и место он
                // занимает то же.
                statusRow(
                    title: String(localized: "Телеметрия"),
                    state: processManager.telemetryStatus == nil ? .unknown : .ok,
                    value: processManager.telemetryStatus
                        ?? String(localized: "сервер ещё не отвечал")
                )
            }
        }
    }

    /// «Работает · PID 12152 · 4 ч 12 мин» — три факта о процессе одной
    /// строкой: он есть, вот его номер, вот сколько он держится. Раньше это
    /// были три отдельные строки на другом экране.
    private var serverValue: String {
        guard processManager.isRunning else { return String(localized: "Остановлен") }
        // PID отдельной частью не добавляется: `state.title` уже говорит
        // «Работает (PID 13760)», и приписка давала «Работает (PID 13760) ·
        // PID 13760» — видно только на экране, в коде обе строки выглядят
        // разумно.
        var parts = [processManager.state.title]
        if let uptime = processManager.uptime { parts.append(RootView.uptimeText(uptime)) }
        return parts.joined(separator: " · ")
    }

    private var proxyValue: String {
        guard app.proxy.state.isRunning else {
            return String(localized: "Остановлен · порт \(settings.configuration.proxyPort.plainDigits)")
        }
        return String(localized: "Работает · порт \(settings.configuration.proxyPort.plainDigits)")
    }

    private var addressValue: String {
        if case .connected(let address, _, _, _) = app.connection { return address }
        return String(localized: "нет подключения")
    }

    /// Путь берётся у окружения, а не из настроек напрямую: не выбранный
    /// человеком путь означает не «пути нет», а «база лежит там, где приложение
    /// её завело по умолчанию». Показывать в этом случае «путь не выбран» —
    /// значит утверждать, что база нигде.
    private var databaseValue: String {
        app.localDatabaseURL.path
    }

    /// Строка «поле — значение» с раз и навсегда заданными размерами.
    ///
    /// Ни высота, ни ширины колонок не зависят от текста, и это здесь главное:
    /// значения в карточке меняются сами по себе — аптайм тикает раз в
    /// секунду, адрес появляется по подключении, сервер отвечает про
    /// телеметрию когда ответит. Пока размеры считались от содержимого,
    /// каждое такое обновление двигало карточку и всё, что под ней.
    ///
    /// Значение занимает всю оставшуюся ширину независимо от своей длины —
    /// потому и не тянет строку за собой; лишнее подрезается посередине.
    private func statusRow(
        title: String, state: CheckState, value: String, isMonospaced: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            StatusDot(state: state)
            Text(title)
                .font(Theme.Font.control)
                .foregroundStyle(Theme.Palette.secondaryText)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(isMonospaced ? Theme.Font.mono : Theme.Font.control)
                .foregroundStyle(isMonospaced ? Theme.Palette.secondaryText : Theme.Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .copyable(value)
        }
        .frame(height: Theme.Size.statusRow)
    }

    // MARK: - Требует решения

    /// Что стоит закрыть — и ничего больше.
    ///
    /// Список собирается из того, что приложение и так знает; ни одной
    /// проверки ради этой карточки не запускается. Пусто — значит пусто:
    /// карточка говорит «всё в порядке» одной строкой, а не показывает
    /// выдуманные пункты, лишь бы не пустовать.
    private struct Decision: Identifiable {
        let id: String
        let text: String
        let isUrgent: Bool
        let action: String?
        let go: (() -> Void)?
    }

    private var decisions: [Decision] {
        var found: [Decision] = []

        // Первый запуск — цепочкой, по звену за раз.
        //
        // Отдельного мастера для этого нет и не будет: мастер — это второй
        // сквозной путь через приложение, свои экраны, которые начнут
        // расходиться с основными. Да и показывается он один раз, а «нечем
        // работать» случается и на второй машине, и после переустановки
        // движка, и когда база отвалилась через полгода.
        //
        // Звенья показываются **по одному**: пока не установлен движок,
        // «нет подключения» — не решение, а следствие, и предлагать его
        // значит отправлять человека туда, где ему нечего нажать.
        if app.environmentStatus.checkedAt != nil, !app.environmentStatus.isEngineInstalled {
            found.append(Decision(
                id: "engine",
                text: String(localized: "Движок ChromaDB не установлен — без него нет ни базы, ни поиска"),
                isUrgent: true,
                action: String(localized: "Установка"),
                go: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Установка"))) }
            ))
        } else if !app.connection.isConnected {
            found.append(Decision(
                id: "connection",
                text: String(localized: "Нет подключения к базе — коллекции и поиск недоступны"),
                isUrgent: true,
                action: String(localized: "Подключение"),
                go: { go(.overview, SidebarSection.overview.tabIndex(String(localized: "Подключение"))) }
            ))
        } else if collectionsModel.collections.isEmpty, !collectionsModel.isLoadingCollections {
            // Подключились, а в базе пусто: следующий шаг — не «настроить
            // поиск», а завести источник. Коллекцию создаст он сам, и звать
            // человека делать её руками значит звать на лишнюю работу.
            found.append(Decision(
                id: "empty-database",
                text: String(localized: "В базе нет ни одной коллекции — добавьте источник, он её и создаст"),
                isUrgent: false,
                action: String(localized: "Источники"),
                go: { go(.sources, nil) }
            ))
        } else if settings.configuration.dataSources.isEmpty {
            // Коллекции есть, а источников нет: база наполнена не отсюда —
            // руками, импортом, чужим клиентом. Это не дефект, но и не то
            // состояние, в котором приложение делает свою работу.
            found.append(Decision(
                id: "no-sources",
                text: String(localized: "Источников нет — коллекции наполнены не приложением, обновлять их некому"),
                isUrgent: false,
                action: String(localized: "Источники"),
                go: { go(.sources, nil) }
            ))
        }
        if sources.problemCount > 0 {
            found.append(Decision(
                id: "sources",
                text: String(localized: "Файлов, которые не удалось прочитать: \(sources.problemCount.plainDigits)"),
                isUrgent: true,
                action: String(localized: "Источники"),
                go: { go(.sources, nil) }
            ))
        }
        if app.proxy.exposure.isExposed {
            found.append(Decision(
                id: "exposure",
                text: String(localized: "Прокси открыт в сеть — к базе может обратиться не только эта машина"),
                isUrgent: true,
                action: String(localized: "Безопасность"),
                go: { go(.security, nil) }
            ))
        }
        if settings.configuration.externalClients.isEmpty {
            found.append(Decision(
                id: "clients",
                text: String(localized: "Ключей клиентов нет — прокси отклоняет все запросы"),
                isUrgent: false,
                action: String(localized: "Клиенты"),
                go: { go(.clients, nil) }
            ))
        }
        if let backup = environment.backups.first(where: { !$0.isIncomplete }) {
            found.append(Decision(
                id: "backup",
                text: String(localized: "Последняя резервная копия — \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)), \(backup.sizeText)"),
                isUrgent: false,
                action: String(localized: "Копии"),
                go: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Копии"))) }
            ))
        } else {
            found.append(Decision(
                id: "no-backup",
                text: String(localized: "Резервных копий базы нет"),
                isUrgent: false,
                action: String(localized: "Копии"),
                go: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Копии"))) }
            ))
        }
        return found
    }

    private var decisionsCard: some View {
        let items = decisions
        return SectionCard(
            title: String(localized: "Требует решения"),
            // Без числительного: «одна вещь», «две вещи», «пять вещей» —
            // три разные формы, и подстановка числа в такую фразу ломает
            // согласование ровно там, где его никто не проверяет.
            subtitle: items.isEmpty
                ? String(localized: "Ничего не ждёт вашего решения.")
                : String(localized: "Ниже — то, что стоит закрыть. Остальное в порядке.")
        ) {
            if items.isEmpty {
                Text("Приложение подключено, файлы прочитаны, доступ настроен.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
            } else {
                VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                    ForEach(items) { item in
                        decisionRow(item)
                    }
                }
            }
        }
    }

    private func decisionRow(_ item: Decision) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(item.isUrgent ? Theme.Palette.attention : Theme.Palette.stopped)
                .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
            Text(item.text)
                .font(Theme.Font.control)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = item.action, let go = item.go {
                Button(action, action: go)
                    .buttonStyle(.chromaSecondary)
            }
        }
        .padding(.horizontal, Theme.Padding.rowHorizontal)
        .padding(.vertical, Theme.Padding.rowVertical)
        .background(
            item.isUrgent
                ? Theme.Palette.attention.opacity(0.09)
                : Theme.Palette.subtleFill
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(
                item.isUrgent ? Theme.Palette.attention.opacity(0.24) : Theme.Palette.border,
                lineWidth: 1
            )
        )
    }

}
