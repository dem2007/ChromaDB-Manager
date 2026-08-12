import SwiftUI

/// Оформление приложения — числа и цвета в одном месте.
///
/// Источник — дизайн-система «macOS Tahoe» проекта: сдержанная стеклянная
/// поверхность, крупные скругления, один синий акцент и текст на трёх уровнях
/// глубины. Здесь лежат её метрики и палитра; правила о том, **что** писать на
/// экране, — в.
///
/// Числа не выдуманы: они взяты из макета до десятых. Полтинники вроде 13,5 и
/// 12,5 — не педантизм, а разница между «текст экрана» и «подпись под
/// контролом», по которой глаз и различает уровни.
enum Theme {
    /// Отступ содержимого экрана от края окна. В макете — 30 по бокам.
    static let contentPadding: CGFloat = 30
    /// Между карточками — 20.
    static let sectionSpacing: CGFloat = 20
    /// Предельная ширина **абзаца текста**: длинная строка не читается.
    ///
    /// К карточкам это правило не применяется. Карточка — не колонка текста,
    /// а таблица, список источников или ряд полей; сжатая до тысячи точек
    /// посреди широкого окна, она оставляет справа пустоту и заставляет
    /// переносить то, что помещалось.
    static let textMaxWidth: CGFloat = 1000

    enum Radius {
        /// Окно 22 · карточка 18 · поповер 14 · поле 9 · кнопка — капсула.
        static let window: CGFloat = 22
        static let card: CGFloat = 18
        static let popover: CGFloat = 14
        static let field: CGFloat = 9
        /// Строка внутри карточки — заметно меньше самой карточки.
        static let row: CGFloat = 13
        /// Полоса о событии — та же строка карточки, только во всю ширину.
        static let banner: CGFloat = 13
        /// Пункт бокового меню.
        static let navItem: CGFloat = 11
        /// Осталось для мест, где форма именно прямоугольная: значки-метки.
        static let chip: CGFloat = 8
        /// Кнопки — капсулы; число нужно там, где форма задаётся радиусом.
        static let control: CGFloat = 999
    }

    enum Padding {
        /// Поля карточки: 24 сверху и снизу, 26 по бокам.
        static let cardHorizontal: CGFloat = 26
        static let cardVertical: CGFloat = 24
        /// Внутри карточки: 16 между блоками, 10 между строками списка.
        static let cardContentSpacing: CGFloat = 16
        static let rowSpacing: CGFloat = 10
        static let banner: CGFloat = 14
        /// Строка списка внутри карточки.
        static let rowHorizontal: CGFloat = 14
        static let rowVertical: CGFloat = 12
    }

    enum Size {
        /// Кнопка 30, вторичная 28, поле 30.
        static let control: CGFloat = 30
        static let secondaryControl: CGFloat = 28
        static let field: CGFloat = 30
        /// Кружок «?» у заголовка карточки.
        static let help: CGFloat = 18
        /// Точка состояния.
        static let statusDot: CGFloat = 8
        /// Высота строки «поле — значение» в карточке состояния.
        ///
        /// Одна на все такие строки, и в этом весь смысл: значения в них
        /// набраны разными шрифтами (13 пунктов обычным, 12 моноширинным),
        /// у которых разная высота строки, и появляются они не разом —
        /// адрес, аптайм и ответ сервера про телеметрию приходят каждый
        /// своим ответом. Пока высота бралась от текста, карточка
        /// пересобиралась под каждый из них.
        static let statusRow: CGFloat = 18
        /// Ширина поповера — 330…350.
        static let popoverWidth: CGFloat = 340
        static let sidebarWidth: CGFloat = 252
        /// Колонка списка объектов внутри экрана — список коллекций в макете.
        static let objectListWidth: CGFloat = 258
        /// Жёлоб под полосу прокрутки — он есть всегда, даже когда прокрутки нет.
        ///
        /// У macOS два стиля полосы, и ведут они себя по-разному:
        ///
        /// * **накладная** рисуется поверх содержимого и появляется только на
        ///   время прокрутки — место под неё нужно отвести самим, иначе она
        ///   ложится на правый край карточки;
        /// * **постоянная** (системная настройка «Всегда показывать полосы
        ///   прокрутки», а также любая подключённая мышь) сама отнимает ширину
        ///   у содержимого — свой жёлоб к ней добавлять нечего, иначе поле
        ///   справа станет вдвое шире левого.
        ///
        /// Приложение приводит свои полосы к накладным (`steadyScrollbar`),
        /// поэтому жёлоб постоянный: он равен ширине накладной полосы, которую
        /// называет сам AppKit, — выдумывать её числом нельзя, она меняется
        /// от версии системы.
        static let scrollGutter: CGFloat = NSScroller.scrollerWidth(
            for: .regular, scrollerStyle: .overlay
        )
    }

    /// Цвет несёт только состояние.
    ///
    /// Оранжевый и красный — это событие, а не украшение: если строка окрашена,
    /// у неё есть действие рядом. Синий отведён под единственную главную кнопку
    /// экрана и под ссылки.
    ///
    /// Каждый цвет объявлен парой «светлая / тёмная»: макет светлый, но
    /// приложение следует системной теме, и ночью белая карточка бьёт по
    /// глазам. Пары подобраны по тому же правилу, что и оригинал, — разница
    /// поверхностей держится на прозрачности, а не на семи оттенках серого.
    enum Palette {
        static let accent = adaptive(light: 0x1F6FEB, dark: 0x4D8CFF)
        static let accentTop = adaptive(light: 0x4D8CFF, dark: 0x5C97FF)
        static let running = adaptive(light: 0x30C14E, dark: 0x3FD860)
        static let attention = adaptive(light: 0xFF9F0A, dark: 0xFFB340)
        static let danger = adaptive(light: 0xE8352A, dark: 0xFF6257)
        static let stopped = adaptive(light: 0xB9B9C0, dark: 0x6E6E76)

        /// Полотно окна и поверхность карточки.
        static let canvas = adaptive(light: 0xFBFBFD, dark: 0x1C1C1E)
        static let card = adaptive(light: 0xFFFFFF, dark: 0x262629)
        static let sidebar = adaptive(light: 0xF6F6F9, dark: 0x1F1F22)

        /// Текст трёх уровней: основной, вторичный, третичный.
        static let primaryText = adaptive(light: 0x1D1D1F, dark: 0xF2F2F5)
        static let secondaryText = adaptive(light: 0x5F5F66, dark: 0xA8A8B0)
        static let captionText = adaptive(light: 0x76767C, dark: 0x9A9AA1)
        /// Надписи-рубрики над группами меню и колонками таблиц.
        static let caption = adaptive(light: 0x9A9AA1, dark: 0x8A8A91)

        /// Волосяная граница карточки и таблицы. Никогда не тень.
        static let border = Color.primary.opacity(0.09)
        static let rowDivider = Color.primary.opacity(0.06)
        /// Мягкая заливка: шапка таблицы, вложенный блок, спокойный контрол.
        static let subtleFill = Color.primary.opacity(0.022)
        static let selectionFill = Color.primary.opacity(0.05)
        /// Выбранный пункт бокового меню. Цвет задан готовым, а не как
        /// «акцент с прозрачностью»: `List.tint` берёт у цвета только тон и
        /// заливает строку целиком, отчего полупрозрачный синий становится
        /// сплошным синим — не мягкой вставкой макета, а самым громким пятном
        /// в окне.
        static let navSelection = adaptive(light: 0xC5D8F8, dark: 0x2E4166)
        static let segmentTrack = Color(white: 0.47).opacity(0.12)

        /// Журналы — бумага, а не текстовое поле.
        static let logBackground = Color.primary.opacity(0.02)
        static let logText = Color.primary.opacity(0.62)
        static let logTimestamp = Color.primary.opacity(0.35)
        static let logSuccess = running

        /// Цвет по системной теме без ассетов: `Color` умеет строиться из
        /// `NSColor` с динамическим провайдером, и это единственный способ
        /// получить пару «светлая/тёмная» в чистом SwiftPM-таргете, где
        /// каталога ассетов нет вовсе (правило 6 — ноль зависимостей).
        static func adaptive(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            })
        }
    }

    /// Типографика: 21/640 заголовок экрана, 15/590 заголовок карточки,
    /// 13,5 основной текст, 12,5 вторичная подпись, 12 моноширинный.
    enum Font {
        static let screenTitle = SwiftUI.Font.system(size: 21, weight: .semibold)
        /// Число на плашке-показателе: «55 813» под подписью «Документов».
        ///
        /// Единственный размер шкалы, который относится не к тексту, а к
        /// числу: плашка читается одним взглядом с расстояния, и 21 у неё
        /// сливается с заголовком экрана, который стоит строкой выше.
        static let metric = SwiftUI.Font.system(size: 26, weight: .bold)
        /// Имя объекта, которому посвящено всё, что ниже: коллекция, источник.
        /// В макете — 17/620, между заголовком экрана и заголовком карточки:
        /// экран называется «Коллекции», а работают всегда с одной из них.
        static let objectTitle = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13.5)
        static let control = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 12.5)
        static let tableHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let tableCell = SwiftUI.Font.system(size: 13)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let monoCell = SwiftUI.Font.system(size: 12, design: .monospaced)
        /// Совсем мелкая подпись: пометка у поля, единица измерения, дата
        /// рядом со строкой списка. Ниже неё в приложении ничего нет —
        /// системная `.caption2` давала десять пунктов, на которых кириллица
        /// в интерфейсе уже не читается.
        static let micro = SwiftUI.Font.system(size: 11.5)
        /// Рубрика над группой: мелкая, вразрядку, прописными.
        static let sectionLabel = SwiftUI.Font.system(size: 10.5, weight: .semibold)
    }

    /// Тени. В макете их две: волосяная у карточки и глубокая у поповера.
    enum Shadow {
        static let cardRadius: CGFloat = 30
        static let cardY: CGFloat = 12
        static let cardOpacity: Double = 0.05
        static let popoverRadius: CGFloat = 44
        static let popoverY: CGFloat = 18
        static let popoverOpacity: Double = 0.3
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// Единственное место, откуда экран берёт свои поля.
    ///
    /// Справа к полю добавлен жёлоб под полосу прокрутки: она накладная и
    /// рисуется поверх содержимого, поэтому место под неё отводится всегда —
    /// иначе карточки на длинной вкладке уже, чем на короткой.
    func pageContentPadding() -> some View {
        padding(.leading, Theme.contentPadding)
            .padding(.trailing, Theme.contentPadding + Theme.Size.scrollGutter)
            .padding(.bottom, Theme.contentPadding)
            .steadyScrollbar()
    }

    /// Жёлоб под полосу прокрутки для содержимого, у которого свои поля.
    func scrollGutter() -> some View {
        padding(.trailing, Theme.Size.scrollGutter)
    }

    /// Полоса прокрутки, которая не меняет ширину содержимого.
    ///
    /// Ставится на содержимое `ScrollView` вместе с `scrollGutter()`.
    func steadyScrollbar() -> some View {
        background(OverlayScrollerSetter().frame(width: 0, height: 0))
    }

    /// Кнопки приложения — капсулы (дизайн-система, раздел «Контролы»).
    func chromaControlShape() -> some View {
        buttonBorderShape(.capsule)
    }
}

/// Приводит полосы прокрутки **всех окон приложения** к накладным.
///
/// Ставится один раз, у корня главного окна: полос в приложении десятки —
/// экраны, вкладки, листы, панели, — и обходить их по одной значит забыть
/// половину. Обход дерева окна дешёвый (сотни вьюх) и делается не чаще, чем
/// раз в полсекунды, и только когда окно само сообщило об обновлении: смена
/// вкладки или открытие листа такое сообщение всегда порождают.
struct WindowScrollerStyle: NSViewRepresentable {
    final class Coordinator {
        var token: NSObjectProtocol?
        var lastRun = Date.distantPast
        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.token = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            guard Date().timeIntervalSince(coordinator.lastRun) > 0.5 else { return }
            coordinator.lastRun = Date()
            Self.applyToAllWindows()
        }
        DispatchQueue.main.async { Self.applyToAllWindows() }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func applyToAllWindows() {
        for window in NSApplication.shared.windows {
            guard let content = window.contentView else { continue }
            apply(in: content)
        }
    }

    private static func apply(in view: NSView) {
        if let scrollView = view as? NSScrollView, scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
        for subview in view.subviews { apply(in: subview) }
    }
}

/// Приводит полосу прокрутки окружающего `NSScrollView` к накладной.
///
/// Постоянная полоса — та, что включается системной настройкой «Всегда
/// показывать полосы прокрутки» и сама собой при подключённой мыши, —
/// **отнимает ширину у содержимого**, и только когда прокрутка есть. Отсюда
/// прыжок: на длинной вкладке карточки уже, чем на короткой, а место, которое
/// приложение отвело под полосу само, складывается с системным.
///
/// Накладная полоса рисуется поверх содержимого и ширину не трогает: жёлоб
/// под неё отведён постоянно, и карточки одной ширины на всех вкладках.
/// Прокрутка колесом, трекпадом и клавишами при этом не меняется — меняется
/// только вид полосы.
///
/// Вьюха нулевого размера: ей нужно попасть в иерархию, чтобы найти свой
/// `NSScrollView`, и больше ничего.
private struct OverlayScrollerSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Через очередь: во время обновления вьюха ещё может не быть вложена
        // в свой NSScrollView, а менять чужую геометрию посреди прохода
        // раскладки AppKit не любит.
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else { return }
            guard scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
    }
}

/// Заголовок раздела в титульной полосе окна.
///
/// Не `navigationTitle` и не элемент тулбара: первый прижат к краю окна и не
/// встаёт над содержимым, второму система рисует подложку с тенью — а нужен
/// просто текст на той же вертикали, что и карточки под ним.
///
/// Текст кладётся прямо в вид титульной полосы, рядом с кнопками окна, а не
/// отдельным `NSTitlebarAccessoryViewController`: вид-спутник **занимает
/// место** в полосе и сдвигает всё, что стоит правее, — из-за этого системная
/// кнопка боковой панели уходила в «переполнение». Обычный подвид ничего не
/// двигает, и кнопка остаётся там, куда её ставит система.
///
/// Отступ слева берётся у самой боковой панели, а не из константы: её ширину
/// можно тянуть мышью, и заголовок обязан ехать вместе с содержимым.
struct TitlebarTitle: NSViewRepresentable {
    let text: String

    final class Coordinator {
        var label: NSTextField?
        var leading: NSLayoutConstraint?
        var observer: NSObjectProtocol?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        DispatchQueue.main.async { install(from: anchor, context: context) }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            install(from: nsView, context: context)
            context.coordinator.label?.stringValue = text
            realign(context.coordinator)
        }
    }

    /// Ставит подпись в полосу окна. Вызывается и при каждом обновлении:
    /// полосу окно пересобирает — например, при выходе из полного экрана, —
    /// и подпись из неё пропадает.
    private func install(from view: NSView, context: Context) {
        guard let window = view.window,
              let titlebar = window.standardWindowButton(.closeButton)?.superview,
              context.coordinator.label?.superview !== titlebar
        else { return }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(label)

        let leading = label.leadingAnchor.constraint(
            equalTo: titlebar.leadingAnchor, constant: Self.leadingInset(in: window)
        )
        // По центру кнопок окна: это и есть строка, в которой полоса держит
        // свой текст.
        let centre = window.standardWindowButton(.closeButton).map {
            label.centerYAnchor.constraint(equalTo: $0.centerYAnchor)
        } ?? label.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor)
        NSLayoutConstraint.activate([leading, centre])

        context.coordinator.label = label
        context.coordinator.leading = leading

        if context.coordinator.observer == nil {
            // Боковую панель тянут мышью и сворачивают — заголовок едет следом.
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: nil,
                queue: .main
            ) { [weak coordinator = context.coordinator] _ in
                if let coordinator { realign(coordinator) }
            }
        }
    }

    private func realign(_ coordinator: Coordinator) {
        guard let window = coordinator.label?.window else { return }
        coordinator.leading?.constant = Self.leadingInset(in: window)
    }

    /// От левого края окна до текста — ровно та вертикаль, на которой стоят
    /// подпись раздела и карточки: ширина боковой панели плюс поле содержимого.
    private static func leadingInset(in window: NSWindow) -> CGFloat {
        let sidebar = splitView(in: window.contentView)
            .flatMap { split -> CGFloat? in
                guard let first = split.arrangedSubviews.first,
                      !split.isSubviewCollapsed(first) else { return nil }
                return first.frame.width
            } ?? 0

        // Со свёрнутой панелью содержимое начинается у края окна, но там стоят
        // кнопки окна и кнопка панели — заголовок отходит от них.
        return sidebar > 1 ? sidebar + Theme.contentPadding : collapsedInset
    }

    /// Со свёрнутой панелью выровнять заголовок с содержимым нельзя: у края
    /// окна стоят его кнопки, а за ними — кнопка панели. Отступ отмерен от
    /// неё, чтобы текст стоял следом, а не поверх.
    private static let collapsedInset: CGFloat = 148

    private static func splitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = splitView(in: child) { return split }
        }
        return nil
    }
}
