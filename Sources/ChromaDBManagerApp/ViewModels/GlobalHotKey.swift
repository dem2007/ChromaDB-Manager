import AppKit
import Carbon.HIToolbox
import ChromaCore

/// Глобальная горячая клавиша.
///
/// Через `RegisterEventHotKey` из Carbon, а не через
/// `NSEvent.addGlobalMonitorForEvents`: монитор событий требует разрешения
/// «Универсальный доступ», то есть права читать **все** нажатия во всех
/// приложениях. Регистрация сочетания такого права не требует — система сама
/// решает, кому отдать нажатие, и приложение не видит ничего лишнего.
/// ТЗ прямо запрещает варианты, требующие лишних разрешений.
///
/// Проверено живьём 6 августа 2026: `RegisterEventHotKey` возвращает `noErr`,
/// и обработчик срабатывает, когда впереди другое приложение.
@MainActor
final class GlobalHotKey {
    /// Что делать по нажатию. Ставится один раз при создании.
    private let action: () -> Void
    private let log: LogHandler?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Сочетание, которое сейчас зарегистрировано, — `nil`, если ничего.
    private(set) var registered: HotKeyCombination?
    /// Последняя ошибка регистрации: сочетание может быть занято другим
    /// приложением, и человеку об этом надо сказать, а не молчать.
    private(set) var problem: String?

    /// Ссылка на себя для C-обработчика: у него нет замыканий с захватом.
    private static var active: GlobalHotKey?

    init(log: LogHandler? = nil, action: @escaping () -> Void) {
        self.log = log
        self.action = action
    }

    /// Приводит регистрацию к желаемому состоянию.
    ///
    /// Вызывается на каждое изменение настроек: включили, выключили, сменили
    /// клавишу. Повторный вызов с тем же сочетанием ничего не делает — иначе
    /// каждая перерисовка настроек снимала бы и ставила клавишу заново.
    func apply(_ preferences: MenuBarPreferences) {
        let wanted = preferences.globalHotKeyEnabled && preferences.hotKey.isUsable
            ? preferences.hotKey
            : nil
        guard wanted != registered else { return }
        unregister()
        guard let wanted else { return }
        register(wanted)
    }

    private func register(_ combination: HotKeyCombination) {
        Self.active = self
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            // Обработчик приходит не на главном потоке — возвращаемся на него
            // до того, как трогать что-либо из интерфейса.
            DispatchQueue.main.async { GlobalHotKey.active?.action() }
            return noErr
        }, 1, &spec, nil, &handler)

        var modifiers: UInt32 = 0
        if combination.command { modifiers |= UInt32(cmdKey) }
        if combination.option { modifiers |= UInt32(optionKey) }
        if combination.control { modifiers |= UInt32(controlKey) }
        if combination.shift { modifiers |= UInt32(shiftKey) }

        let id = EventHotKeyID(signature: OSType(0x43_44_4D_31), id: 1)  // 'CDM1'
        let status = RegisterEventHotKey(
            combination.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference
        )
        if status == noErr {
            registered = combination
            problem = nil
            // В журнал пишется и то, доверено ли приложение системой:
            // это и есть ответ на вопрос ТЗ «требует ли способ разрешения».
            log?(.info, "Строка меню", "Горячая клавиша \(combination.display) зарегистрирована; разрешение «Универсальный доступ»: \(AXIsProcessTrusted() ? "выдано" : "не выдано")")
        } else {
            // Чаще всего это «сочетание занято»: система отдаёт клавишу
            // первому, кто её попросил, и вторым остаётся только сказать.
            registered = nil
            problem = String(localized: "Сочетание \(combination.display) занято другим приложением — выберите другое.")
            log?(.warning, "Строка меню", "Не удалось зарегистрировать \(combination.display): код \(status)")
            unregister()
        }
    }

    private func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        registered = nil
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
