import SwiftUI
import ChromaCore

/// Настройки строки меню, быстрого поиска и горячей клавиши.
///
/// Оба варианта поведения доступны и оба выключаемы: ТЗ прямо запрещает
/// навязывать «жизнь в строке меню».
struct MenuBarSettingsCard: View {
    @EnvironmentObject private var settings: SettingsStore

    private var preferences: MenuBarPreferences { settings.configuration.menuBar }

    var body: some View {
        SectionCard(
            title: String(localized: "Строка меню и быстрый поиск"),
            subtitle: String(localized: "Значок в строке меню показывает, идёт ли индексация, и позволяет поставить её на паузу и поискать, не открывая окно.")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "Показывать значок в строке меню"), isOn: Binding(
                    get: { preferences.showsIcon },
                    set: { settings.configuration.menuBar.showsIcon = $0 }
                ))

                Toggle(String(localized: "Оставаться в строке меню после закрытия окна"), isOn: Binding(
                    get: { preferences.keepsRunningWithoutWindow },
                    set: { settings.configuration.menuBar.keepsRunningWithoutWindow = $0 }
                ))
                // Без значка приложение без окна было бы недостижимо ничем,
                // кроме принудительного завершения, — поэтому связка запрещена
                // не подсказкой, а тем, что переключатель недоступен.
                .disabled(!preferences.showsIcon)
                Text(preferences.showsIcon
                     ? String(localized: "Значок в Dock при этом убирается. По умолчанию выключено: приложение, которое не закрывается по красной кнопке, воспринимается как сломанное.")
                     : String(localized: "Недоступно без значка в строке меню: приложение без окна и без значка нельзя было бы ни открыть, ни закрыть."))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Главное, ради чего это включают: агент продолжает работать
                // с базой при закрытом окне. Состояние моста видно
                // в самом окошке строки меню — там же, где поиск.
                Text("MCP-сервер при этом остаётся поднятым: агент работает с базой, пока приложение живёт в строке меню. Его состояние видно в окошке значка.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 2)

                Toggle(String(localized: "Глобальная горячая клавиша"), isOn: Binding(
                    get: { preferences.globalHotKeyEnabled },
                    set: { settings.configuration.menuBar.globalHotKeyEnabled = $0 }
                ))
                HStack(spacing: 8) {
                    Text(String(localized: "Сочетание"))
                    Picker("", selection: Binding(
                        get: { preferences.hotKey.keyCode },
                        set: { settings.configuration.menuBar.hotKey.keyCode = $0 }
                    )) {
                        ForEach(HotKeyCombination.selectableKeys, id: \.code) { key in
                            Text(key.name).tag(key.code)
                        }
                    }
                    .labelsHidden().frame(width: 120)
                    Text(preferences.hotKey.display)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .disabled(!preferences.globalHotKeyEnabled)
                Text(String(localized: "Модификаторы фиксированы: ⌃⌥⌘ — сочетание, за которым в системе почти ничего не закреплено. Разрешения на управление компьютером не требуется: клавиша регистрируется в системе, а не читает чужие нажатия."))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 2)

                Stepper(value: Binding(
                    get: { preferences.quickSearchResultCount },
                    set: { settings.configuration.menuBar.quickSearchResultCount = max(1, min(20, $0)) }
                ), in: 1...20) {
                    Text(String(localized: "Результатов в быстром поиске: \(preferences.quickSearchResultCount)"))
                }
                Text(String(localized: "Коллекция для быстрого поиска выбирается в самом меню — там же, где ищут."))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
    }
}
