import SwiftUI
import ChromaCore

/// Карточка — единица экрана: одна тема, свой заголовок, своё объяснение.
///
/// `help` — второй уровень текста дизайн-системы: кружок «?» у заголовка,
/// по клику — поповер на 2–4 предложения о том, **почему** так устроено.
/// На экране остаётся то, что меняет решение прямо сейчас; причина живёт
/// под «?». Необратимое, пересчёт и остановка сервера под «?» не прячутся
/// никогда — для них место на самом экране.
struct SectionCard<Content: View>: View {
    /// Тон карточки. Обычная — белая; `danger` — та, где живёт необратимое:
    /// у неё красная рамка и лёгкая заливка, чтобы человек видел, куда попал,
    /// ещё до того, как прочтёт заголовок.
    enum Tone { case plain, danger }

    let title: String
    var subtitle: String?
    /// Объяснение под «?». `nil` — кружка нет вовсе, а не пустой поповер.
    var help: String?
    var tone: Tone = .plain
    @ViewBuilder var content: Content

    @State private var showingHelp = false

    private var background: Color {
        tone == .danger ? Theme.Palette.danger.opacity(0.06) : Theme.Palette.card
    }

    private var border: Color {
        tone == .danger ? Theme.Palette.danger.opacity(0.35) : Theme.Palette.border
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.Font.cardTitle)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if help != nil {
                    Spacer(minLength: 8)
                    HelpButton(text: help ?? "", isPresented: $showingHelp)
                }
            }
            content
        }
        .padding(.horizontal, Theme.Padding.cardHorizontal)
        .padding(.vertical, Theme.Padding.cardVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(border, lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(Theme.Shadow.cardOpacity),
            radius: Theme.Shadow.cardRadius,
            y: Theme.Shadow.cardY
        )
    }
}

/// Лист — тот же экран, только поверх текущего.
///
/// Правила экрана к нему применяются целиком: заголовок один и в шапке,
/// содержимое разложено карточками по ходу работы, длинные объяснения живут
/// под «?», а не абзацами между полями. Отличие ровно одно — **подвал**: у
/// листа он есть, потому что «Отмена» и «Добавить» относятся ко всему листу,
/// а не к одной из его карточек. На экране такого ряда не бывает.
struct SheetShell<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    /// Объяснение под «?» у заголовка листа — о листе целиком.
    var help: String?
    var width: CGFloat = 720
    /// `nil` — лист ровно по своему содержимому. Так живут подтверждения:
    /// у них нечего прокручивать, и пустое место под текстом ничего не значит.
    var height: CGFloat? = 720
    /// Прокрутка тела. Выключается вместе с высотой: без неё `ScrollView`
    /// внутри столбца без высоты остаётся ни с чем.
    var scrolls: Bool = true
    @ViewBuilder var content: Content
    /// Кнопки подвала. Синяя среди них — одна.
    @ViewBuilder var actions: Actions

    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.Font.objectTitle)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let help { HelpButton(text: help, isPresented: $showingHelp) }
            }
            .padding(.horizontal, Theme.Padding.cardHorizontal)
            .padding(.top, 22)
            .padding(.bottom, 16)

            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                        content
                    }
                    .padding(.horizontal, Theme.Padding.cardHorizontal)
                    .padding(.bottom, 20)
                    .scrollGutter()
                    .steadyScrollbar()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                    content
                }
                .padding(.horizontal, Theme.Padding.cardHorizontal)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                actions
            }
            .padding(.horizontal, Theme.Padding.cardHorizontal)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .overlay(
                Rectangle().fill(Theme.Palette.border).frame(height: 1),
                alignment: .top
            )
        }
        .frame(width: width, height: height)
        .background(Theme.Palette.canvas)
    }
}

/// Плашка-показатель: подпись сверху, число под ней.
///
/// Из макета: ряд плашек — первое, что видно на «Обзоре». Плашка отвечает на
/// вопрос «сколько», а не «что не так»: цвета у неё нет, состояние — дело
/// карточек ниже. Нажатие уводит туда, где этим числом можно управлять, —
/// иначе оно было бы тупиком.
struct StatTile: View {
    let title: String
    let value: String
    var go: (() -> Void)?

    var body: some View {
        Button {
            go?()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
                    .lineLimit(1)
                Text(value)
                    .font(Theme.Font.metric)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(Theme.Shadow.cardOpacity),
                radius: Theme.Shadow.cardRadius,
                y: Theme.Shadow.cardY
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .disabled(go == nil)
    }
}

/// Точка выбора у варианта — вместо системного `Picker(.radioGroup)`.
///
/// Системная радиокнопка приносит свой шрифт и свои отступы, а вариант в
/// макете — целая строка с подписью, по которой и попадают мышью.
struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Theme.Palette.accent : Theme.Palette.card)
            .frame(width: 16, height: 16)
            .overlay(
                Circle().strokeBorder(
                    isOn ? Color.clear : Theme.Palette.captionText.opacity(0.45), lineWidth: 1
                )
            )
            .overlay(Circle().fill(.white).frame(width: 6, height: 6).opacity(isOn ? 1 : 0))
    }
}

/// Кружок «?» у заголовка карточки — второй уровень текста.
struct HelpButton: View {
    let text: String
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(verbatim: "?")
                .font(Theme.Font.tableHeader)
                .foregroundStyle(Theme.Palette.captionText)
                .frame(width: Theme.Size.help, height: Theme.Size.help)
                .background(Circle().fill(Theme.Palette.subtleFill))
                .overlay(Circle().strokeBorder(Theme.Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Почему так устроено"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(Theme.Font.caption)
                .lineSpacing(2)
                .foregroundStyle(Theme.Palette.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(width: Theme.Size.popoverWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// «Для опытных» — то, что настраивают редко и осознанно.
///
/// Дизайн-система прямо называет таких жильцов: параметры индекса, JSON-фильтр,
/// таймауты. Они не исчезают — они перестают быть первым, что видно, когда
/// человек открыл экран ради другого. Состояние запоминается на место, а не
/// на всё приложение.
struct AdvancedSection<Content: View>: View {
    let place: String
    var title: String = String(localized: "Для опытных")
    @ViewBuilder var content: Content

    @AppStorage private var isExpanded: Bool

    init(place: String, title: String = String(localized: "Для опытных"), @ViewBuilder content: () -> Content) {
        self.place = place
        self.title = title
        self.content = content()
        _isExpanded = AppStorage(wrappedValue: false, "advanced.\(place)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        } label: {
            Text(title)
                .font(Theme.Font.control)
                .foregroundStyle(Theme.Palette.secondaryText)
                .togglesDisclosure($isExpanded)
        }
    }
}

/// «Как это работает» — третий уровень текста: устройство раздела целиком.
///
/// Читают один раз и больше не возвращаются, поэтому по умолчанию свёрнут.
/// Состояние запоминается на экран — не глобально: раскрытый на «Источниках»
/// блок ничего не говорит о том, нужен ли он на «Логах».
struct HowItWorks<Content: View>: View {
    let screen: String
    @ViewBuilder var content: Content

    @AppStorage private var isExpanded: Bool

    init(screen: String, @ViewBuilder content: () -> Content) {
        self.screen = screen
        self.content = content()
        _isExpanded = AppStorage(wrappedValue: false, "howItWorks.\(screen)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
        } label: {
            Text("Как это работает")
                .font(Theme.Font.control)
                .foregroundStyle(Theme.Palette.primaryText)
                .togglesDisclosure($isExpanded)
        }
        .padding(.horizontal, Theme.Padding.rowHorizontal)
        .padding(.vertical, Theme.Padding.rowVertical)
        .background(Theme.Palette.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }
}

extension View {
    /// Весь заголовок раскрывашки — кнопка, а не одна стрелка.
    ///
    /// На macOS `DisclosureGroup` откликается только на треугольник слева:
    /// подпись рядом с ним выглядит нажимаемой, но не нажимается. Промах
    /// мимо цели в шесть точек — это не придирка, а обычное «ткнул и ничего
    /// не произошло».
    ///
    /// `contentShape` нужен вместе с растяжкой по ширине: без него нажатие
    /// ловил бы только сам текст, а пустое место справа от него — нет.
    func togglesDisclosure(_ isExpanded: Binding<Bool>) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
            }
    }
}

/// Подпись, ширина которой не зависит от начертания.
///
/// Выделять выбранный пункт полужирным правильно, а менять из-за этого его
/// размер — нет: полужирный текст шире обычного, и переключатель ёрзал при
/// каждом нажатии, сдвигая заодно и соседние пункты. Место занимает
/// **невидимый полужирный двойник**, а поверх него рисуется настоящая
/// подпись — то есть ширина всегда одна, наибольшая, а меняется только вид.
///
/// Двойник скрыт от озвучивания: иначе VoiceOver прочитал бы подпись дважды.
struct SteadyWeightLabel: View {
    let title: String
    let font: Font
    let isEmphasised: Bool
    let colour: Color

    /// Начертание, по которому считается место. Не зависит от состояния —
    /// в этом весь смысл.
    static func sizingFont(_ font: Font) -> Font { font.weight(.semibold) }

    var body: some View {
        Text(title)
            .font(Self.sizingFont(font))
            .opacity(0)
            .accessibilityHidden(true)
            .overlay(
                Text(title)
                    .font(isEmphasised ? font.weight(.semibold) : font)
                    .foregroundStyle(colour)
            )
    }
}

/// A native-looking segmented control: one track, a white pill on the chosen
/// segment, no gap between them.
struct SegmentedSelector<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                SteadyWeightLabel(
                    title: option.title,
                    font: Theme.Font.caption,
                    isEmphasised: isSelected,
                    colour: isSelected ? Theme.Palette.primaryText : Theme.Palette.secondaryText
                )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isSelected ? Theme.Palette.card : .clear)
                            .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1.5, y: 1)
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? Theme.Palette.border : .clear, lineWidth: 1
                        )
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option.value }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.Palette.segmentTrack))
    }
}

/// Column captions of a table: small caps, grey, and the same everywhere.
///
/// A `nil` width means «take what is left»; the rest are fixed, so the caption
/// and the cell under it line up without a layout guide.
struct TableHeaderRow: View {
    let columns: [(title: String, width: CGFloat?)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Text(column.title.uppercased())
                    .font(Theme.Font.tableHeader)
                    .foregroundStyle(Theme.Palette.caption)
                    .kerning(0.4)
                    .lineLimit(1)
                    .frame(width: column.width, alignment: .leading)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Padding.rowHorizontal)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.subtleFill)
    }
}

/// A bordered container whose children are rows separated by hairlines —
/// the table look from the mockups, without a real NSTableView.
struct TableCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
    }
}

/// One row of a `TableCard`.
struct TableRow<Content: View>: View {
    var isFirst: Bool = false
    var isHighlighted: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(Theme.Palette.rowDivider).frame(height: 1)
            }
            HStack(spacing: 12) { content }
                .padding(.horizontal, Theme.Padding.rowHorizontal)
                .padding(.vertical, Theme.Padding.rowVertical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHighlighted ? Color.accentColor.opacity(0.06) : .clear)
        }
    }
}

struct MessageBanner: View {
    enum Kind { case error, info, success, warning }

    let kind: Kind
    let text: String
    var onDismiss: (() -> Void)?

    /// Цвет несёт состояние, а не украшает: окрашенная полоса — это событие,
    /// у которого рядом есть действие (дизайн-система, раздел «Цвет»).
    private var color: Color {
        switch kind {
        case .error: return Theme.Palette.danger
        case .info: return Theme.Palette.accent
        case .success: return Theme.Palette.running
        case .warning: return Theme.Palette.attention
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Точка вместо иконки-эмоции: «статусы — точка 8 px и текст
            // словами». Треугольник с восклицательным знаком кричит там, где
            // достаточно сказать.
            Circle()
                .fill(color)
                .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                .padding(.top, 5)
            Text(text)
                .font(Theme.Font.body)
                .copyable(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.captionText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Padding.rowHorizontal)
        .padding(.vertical, Theme.Padding.rowVertical)
        .background(color.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.banner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.banner)
                .strokeBorder(color.opacity(0.24), lineWidth: 1)
        )
    }
}

/// Monospaced auto-scrolling console for command output.
///
/// Every place that shows a log — this console, the server output, the Logs
/// screen — uses the same block: plain paper, monospaced, one continuous text,
/// never a card per line.
struct ConsoleView: View {
    let lines: [String]
    var minHeight: CGFloat = 160
    /// Off when the reader is scrolling back through the output by hand.
    var autoScroll: Bool = true
    var caption: String?

    var body: some View {
        LogBlock(caption: caption, minHeight: minHeight) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            // Long command output wraps; otherwise a single wide
                            // line would stretch the whole window.
                            Text(line)
                                .font(Theme.Font.mono)
                                .lineSpacing(3)
                                .foregroundStyle(Theme.Palette.logText)
                                .copyable(line)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: lines.count) { _, count in
                    guard autoScroll, count > 0 else { return }
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}

/// The shared shell for anything log-shaped ( of the styling brief).
struct LogBlock<Content: View>: View {
    var caption: String?
    var minHeight: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption {
                Text(caption.uppercased())
                    .font(Theme.Font.tableHeader)
                    .kerning(0.5)
                    .foregroundStyle(Theme.Palette.caption)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(Theme.Palette.logBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// Uniform status indicator: one size, colour carries the meaning.
/// Green — fine, red — broken, orange — works but needs attention,
/// grey — could not be determined.
struct StatusDot: View {
    let state: CheckState
    var diameter: CGFloat = Theme.Size.statusDot

    private var color: Color {
        switch state {
        case .ok: return Theme.Palette.running
        case .warning: return Theme.Palette.attention
        case .missing: return Theme.Palette.danger
        case .unknown, .checking: return Theme.Palette.stopped
        }
    }

    private var label: String {
        switch state {
        case .ok: return String(localized: "в порядке")
        case .warning: return String(localized: "требует внимания")
        case .missing: return String(localized: "не найдено")
        case .unknown: return String(localized: "статус не определён")
        case .checking: return String(localized: "проверяется")
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(label)
            .help(label)
    }
}

/// Кнопки приложения — капсулы, и главная на экране одна.
///
/// Дизайн-система: «Синий отведён под единственную главную кнопку экрана и под
/// ссылки; вторая синяя кнопка в одном ряду запрещена». Поэтому вид кнопки
/// здесь — не украшение, а утверждение о её месте: `.primary` в ряду может
/// быть только одна, `.danger` окрашивает то, что необратимо.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, secondary, danger }

    let kind: Kind
    /// Цвет выбранного состояния — `nil` значит «не выбрана».
    ///
    /// Своим полем, а не `.tint`: этот стиль рисует и заливку, и цвет надписи
    /// сам, поэтому `.tint` до него не доходит вовсе. Живой случай: кнопки
    /// «релевантен / частично / нерелевантен» в стенде оценки красились
    /// именно так — отметка ставилась, а кнопка не менялась ничем, и человек
    /// жал её второй раз, снимая только что поставленную оценку.
    var chosen: Color?
    /// Держать ширину по выбранному состоянию, даже когда кнопка не выбрана
    ///.
    ///
    /// Нужно кнопкам выбора: у выбранной начертание `.medium`, у прочих
    /// `.regular`, и полужирная надпись шире — тройка «релевантен / частично
    /// / нерелевантен» дёргалась при каждом нажатии. Место занимает невидимый
    /// двойник надписи в выбранном начертании.
    ///
    /// Отдельным полем, а не всегда: обычная кнопка выбранной не бывает,
    /// и расширять её ради состояния, в которое она не попадёт, незачем.
    var reservesEmphasisWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let height = kind == .secondary ? Theme.Size.secondaryControl : Theme.Size.control
        let size: CGFloat = kind == .secondary ? 12.5 : 13
        let emphasised = kind == .primary || kind == .danger || chosen != nil
        let label = configuration.label
            .font(.system(size: size, weight: emphasised ? .medium : .regular))
            .foregroundStyle(foreground)

        return Group {
            if reservesEmphasisWidth {
                configuration.label
                    .font(.system(size: size, weight: .medium))
                    .opacity(0)
                    .accessibilityHidden(true)
                    .overlay(label)
            } else {
                label
            }
        }
            .padding(.horizontal, kind == .secondary ? 13 : (kind == .normal ? 14 : 16))
            .frame(height: height)
            .background(background)
            .overlay(Capsule().strokeBorder(chosen ?? Theme.Palette.border, lineWidth: 1))
            .clipShape(Capsule())
            .shadow(color: glow, radius: 8, y: 2)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.Palette.captionText }
        if chosen != nil { return .white }
        switch kind {
        case .primary, .danger: return .white
        case .normal, .secondary: return Theme.Palette.primaryText
        }
    }

    @ViewBuilder private var background: some View {
        if !isEnabled {
            Capsule().fill(Theme.Palette.selectionFill)
        } else if let chosen {
            Capsule().fill(chosen)
        } else {
            switch kind {
            case .primary:
                Capsule().fill(LinearGradient(
                    colors: [Theme.Palette.accentTop, Theme.Palette.accent],
                    startPoint: .top, endPoint: .bottom
                ))
            case .danger:
                Capsule().fill(LinearGradient(
                    colors: [Theme.Palette.danger.opacity(0.85), Theme.Palette.danger],
                    startPoint: .top, endPoint: .bottom
                ))
            case .normal, .secondary:
                Capsule().fill(Theme.Palette.card)
            }
        }
    }

    private var glow: Color {
        guard isEnabled else { return .clear }
        if let chosen { return chosen.opacity(0.35) }
        switch kind {
        case .primary: return Theme.Palette.accent.opacity(0.45)
        case .danger: return Theme.Palette.danger.opacity(0.4)
        case .normal, .secondary: return .black.opacity(0.06)
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    /// Главная кнопка экрана — одна.
    static var chromaPrimary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .primary) }
    static var chromaNormal: CapsuleButtonStyle { CapsuleButtonStyle(kind: .normal) }
    /// Кнопка выбора: цвет — «выбрана», `nil` — «не выбрана».
    static func chromaChoice(_ chosen: Color?) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: .normal, chosen: chosen, reservesEmphasisWidth: true)
    }
    static var chromaSecondary: CapsuleButtonStyle { CapsuleButtonStyle(kind: .secondary) }
    /// Необратимое действие.
    static var chromaDanger: CapsuleButtonStyle { CapsuleButtonStyle(kind: .danger) }
}

struct CheckRow: View {
    let item: CheckItem
    var action: (title: String, handler: () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Fixed lane so every title starts at the same x.
            StatusDot(state: item.state)
                .frame(width: 16, alignment: .center)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.Font.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(item.detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
                    .copyable(item.detail)
                    .fixedSize(horizontal: false, vertical: true)
                // Подсказка — пояснение, а не состояние: состояние уже
                // сказано точкой слева. Оранжевым она красилась просто
                // потому, что оранжевый заметнее, — ровно то, что правило
                // «цвет только состояние» и запрещает.
                if let hint = item.hint {
                    Text(hint)
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let action {
                Button(action.title, action: action.handler)
                    .buttonStyle(.chromaSecondary)
                    .layoutPriority(1)
            }
        }
        .padding(.vertical, 3)
        // Still a floor, so a row that grows from one line to two when the probe
        // lands does not shove everything below it — but a much lower one: the
        // status screen was the airiest page in the app.
        .frame(minHeight: 44, alignment: .top)
    }
}

struct MetadataTable: View {
    let metadata: ChromaMetadata?

    var body: some View {
        if let metadata, !metadata.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(metadata.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top, spacing: 6) {
                        Text(key)
                            .font(Theme.Font.mono)
                            .foregroundStyle(.secondary)
                        // A long value must wrap, not push the window wider.
                        Text(metadata[key]?.displayString ?? "—")
                            .font(Theme.Font.mono)
                            .copyable(metadata[key]?.displayString ?? "")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            Text("нет метаданных").font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Small helper so screens can disable themselves while an async job runs.
    @ViewBuilder
    func disabledWhileBusy(_ busy: Bool) -> some View {
        disabled(busy).opacity(busy ? 0.6 : 1)
    }

    /// Adds a "copy" context menu instead of `.textSelection(.enabled)`.
    ///
    /// On macOS selectable text is backed by an NSTextField (SwiftUI's
    /// `SelectionOverlay`). When SwiftUI updates that field's font while the
    /// window is already inside its layout pass, AppKit raises an exception
    /// from `-[NSWindow _postWindowNeedsUpdateConstraints]` and the app dies —
    ///,. A context menu carries no AppKit control,
    /// so the crash cannot happen, and the text stays copyable.
    func copyable(_ value: String) -> some View {
        contextMenu {
            Button(String(localized: "Скопировать")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        }
    }
}

/// Строка прогресса из очереди — **отдельной вьюхой**, и это не украшательство.
///
/// Очередь сообщает о прогрессе четыре раза в секунду. Пока её читало тело
/// большого экрана, каждое такое сообщение перестраивало весь экран целиком —
/// тот же дефект, что был у времени работы сервера, только вчетверо
/// чаще и на самых тяжёлых экранах приложения. Наблюдение живёт здесь, и
/// перерисовывается одна эта строка.
struct QueueProgressRow: View {
    @EnvironmentObject private var queueMirror: QueueMirror
    /// По началу названия экран находит «свою» задачу, не зная про очередь
    /// ничего больше.
    let titlePrefix: String
    /// Что дописать под полосой — например «пауза».
    var footnote: (() -> AnyView)?

    var body: some View {
        if let task = queueMirror.task(titledWith: titlePrefix) {
            ProgressView(value: task.progress ?? 0) {
                Text(task.state == .queued
                     ? String(localized: "В очереди — ждёт освобождения модели")
                     : (task.detail ?? task.title))
                    .font(Theme.Font.caption)
            }
            if let footnote { footnote() }
        }
    }
}
