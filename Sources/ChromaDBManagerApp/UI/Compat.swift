import SwiftUI

/// Единственное место, где интерфейс зовёт API новее macOS 14.
///
/// Базовый слой приложения держится того, что есть на macOS 14, — тогда вид
/// Sonoma/Sequoia на 14–15 и Liquid Glass на 26 система даёт сама, из одного
/// кода. Всё, что появилось позже, живёт здесь, обёрткой с веткой для 14;
/// прямых вызовов таких API в экранах быть не должно. Стекло на 14–15
/// не имитируется: там кнопка просто системная.
extension View {
    /// Главная кнопка экрана или листа — одна на экран.
    ///
    /// На 26 — стеклянная выделенная, на 14–15 — `borderedProminent`.
    /// `keyboardShortcut(.defaultAction)` ставит тот, кто зовёт: не у каждой
    /// главной кнопки Return — правильная клавиша (в форме с многострочным
    /// полем он нужен для перевода строки).
    @ViewBuilder func primaryButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Убирает заголовок раздела из полосы тулбара, когда на его месте стоят
    /// вкладки (v3).
    ///
    /// Вкладки по центру тулбара прыгали: центр считается по свободному
    /// месту, а кнопки справа у каждой вкладки свои. Слева, на месте
    /// заголовка, они стоят неподвижно. Заголовок окна при этом остаётся
    /// (меню «Окно», Mission Control). На 14 такого API нет — там заголовок
    /// стоит после вкладок.
    /// Красная кнопка — там, где принимается необратимое решение: главная
    /// кнопка листа, подтверждающего удаление, и тревожная экстренная
    /// остановка. Return её не нажимает (`.defaultAction` не ставится).
    /// Кнопки, которые к решению только подводят, остаются обычными: красная
    /// есть в самом вопросе.
    @ViewBuilder func destructiveButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent).tint(.red)
        } else {
            self.buttonStyle(.borderedProminent).tint(.red)
        }
    }

    /// Красный текст у обычной кнопки — для самого разрушительного действия
    /// окна, которое ещё спросит подтверждение («Удалить все данные…»).
    func destructiveTextStyle() -> some View {
        foregroundStyle(.red)
    }

    @ViewBuilder func hidesToolbarTitle(_ hides: Bool) -> some View {
        if #available(macOS 15, *) {
            if hides { self.toolbar(removing: .title) } else { self }
        } else {
            // На 14 `toolbar(removing:)` нет, и заголовок вставал между
            // вкладками и кнопками: полоса переполнялась, вкладки уезжали.
            // Окно прячет его само — это AppKit, он есть везде; заголовок
            // для меню «Окно» и Mission Control остаётся, как и на 15+.
            self.background(WindowTitleVisibility(hidden: hides))
        }
    }

    /// Строка, прибитая к низу прокручиваемого списка (состояние подключения
    /// под сайдбаром).
    ///
    /// На 26 — `safeAreaBar`: что уезжает под строку, система размывает сама.
    /// На 14–15 — `safeAreaInset` на материале `.bar`: без фона строки
    /// последний пункт списка при низком окне просвечивает сквозь неё, и
    /// щелчок по нему попадает в строку.
    @ViewBuilder func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            self.safeAreaBar(edge: .bottom, content: bar)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    bar()
                }
                .background(.bar)
            }
        }
    }
}

/// Видимость заголовка в полосе окна — для macOS 14 (`hidesToolbarTitle`).
///
/// Окно узнаётся, когда вид в него попал (`viewDidMoveToWindow`), а не при
/// первом обновлении: тогда окна у вида ещё нет. Раздел меняется — меняется
/// и видимость: у разделов без вкладок заголовок виден.
private struct WindowTitleVisibility: NSViewRepresentable {
    let hidden: Bool

    final class Probe: NSView {
        var hidesTitle = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            window?.titleVisibility = hidesTitle ? .hidden : .visible
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.hidesTitle = hidden
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.hidesTitle = hidden
    }
}

#Preview {
    HStack {
        Button("Отменить" as String) {}
            .keyboardShortcut(.cancelAction)
        Button("Сделать копию" as String) {}
            .primaryButtonStyle()
            .keyboardShortcut(.defaultAction)
    }
    .padding()
}
