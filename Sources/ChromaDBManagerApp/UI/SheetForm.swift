import SwiftUI

/// Ширина листа: обычный — для нескольких полей, широкий — для текста
/// и таблиц (документ, импорт).
enum SheetWidth {
    case regular
    case wide

    var points: CGFloat {
        switch self {
        case .regular: return 480
        case .wide: return 640
        }
    }
}

/// Высота листа: по содержимому — для короткой формы; высокий — для длинной,
/// которая прокручивается, а кнопки остаются на месте (профиль поиска,
/// пересчёт векторов).
enum SheetHeight {
    case fitting
    case tall

    var points: CGFloat? {
        switch self {
        case .fitting: return nil
        case .tall: return 620
        }
    }
}

/// Лист с формой и своим рядом кнопок внизу справа.
///
/// Девятый файл `UI/` сверх перечня: лист нужен почти каждому экрану,
/// и ширина его — число, а числа разрешены только здесь.
struct SheetFrame<Content: View, Actions: View>: View {
    var width: SheetWidth = .regular
    var height: SheetHeight = .fitting
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        if let points = height.points {
            frame.frame(width: width.points, height: points)
        } else {
            frame
                .frame(width: width.points)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var frame: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
                .toggleStyle(.switch)
            HStack {
                actions
            }
            .padding()
        }
    }
}

/// Лист-форма: «Отменить» (Esc) и главная кнопка (Return).
///
/// У разрушительного действия главная кнопка — обычного вида с
/// `role: .destructive`, и Return её не нажимает: удалить случайно нельзя.
struct SheetForm<Content: View>: View {
    var width: SheetWidth = .regular
    var cancel: () -> Void
    var confirmTitle: String
    var confirmDisabled = false
    var isDestructive = false
    /// Идёт работа — рядом с кнопками крутится индикатор.
    var isWorking = false
    var confirm: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        SheetFrame(width: width) {
            content
        } actions: {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button(String(localized: "Отменить"), action: cancel)
                .keyboardShortcut(.cancelAction)
            if isDestructive {
                Button(confirmTitle, role: .destructive, action: confirm)
                    .destructiveButtonStyle()
                    .disabled(confirmDisabled)
            } else {
                Button(confirmTitle, action: confirm)
                    .primaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmDisabled)
            }
        }
    }
}

extension View {
    /// Многострочное поле формы (`TextEditor`): не ниже нескольких строк и
    /// не выше экрана. Без верхней границы поле в форме растёт вместе с
    /// текстом, и вставленный документ выталкивает всё, что под ним.
    func textArea() -> some View {
        frame(minHeight: 80, maxHeight: 240)
    }
}

// MARK: - Просмотр документа

extension View {
    /// Лист просмотра документа — большой и растягиваемый: документ читают.
    func documentSheetFrame() -> some View {
        frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 760)
    }

    /// Ячейка листа таблицы в просмотре: одна ширина на все колонки —
    /// длинная ячейка не раздувает свою колонку на весь лист.
    func tableCellWidth() -> some View {
        frame(width: 180, alignment: .leading)
    }
}

// MARK: - Графики

extension View {
    /// Небольшой график в строке формы (гистограмма длин в «Обзоре»
    /// коллекции): высота своя, ширина — строки.
    func formChartHeight() -> some View {
        frame(height: 120)
    }
}

// MARK: - Окно строки меню

extension View {
    /// Всплывающее окно значка в строке меню. Высота задана жёстко, а не по
    /// содержимому: `MenuBarExtra` защёлкивает размер при первом показе и под
    /// появившиеся результаты поиска не растёт — они оказывались за краем.
    /// Высота — по содержимому (v6): без результатов под полем поиска не
    /// остаётся пустоты; результаты появляются по мере поиска.
    func menuBarPanel() -> some View {
        padding()
            .frame(width: 400, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Список результатов быстрого поиска: в плавающей панели — во всю её
    /// высоту, в окне значка (высота по содержимому) — своей высоты.
    @ViewBuilder
    func resultsHeight(fillsHeight: Bool) -> some View {
        if fillsHeight {
            frame(maxHeight: .infinity)
        } else {
            frame(height: 260)
        }
    }
}

// MARK: - Панель быстрого поиска

/// Размер плавающей панели быстрого поиска (AppKit `NSPanel`): панель по
/// клавише открывается ради результатов, и показывать их в щели высотой в
/// две строки бессмысленно.
enum QuickSearchPanelSize {
    static let size = CGSize(width: 460, height: 420)
}

// MARK: - Окно «Настройки» и числовые поля

extension View {
    /// Окно «Настройки» — фиксированной ширины, как у системных.
    func settingsWindowWidth() -> some View {
        frame(width: 560)
    }

    /// Вкладка «Настроек» — без прокрутки, высотой по содержимому (v3):
    /// окно подстраивается под вкладку, как у системных настроек. Вкладка,
    /// которой не хватает места, делится, а не прокручивается.
    func settingsTabForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Поле лимита ключа: помещается «без лимита» и шестизначное число.
    func limitFieldWidth() -> some View {
        frame(width: 120)
    }

    /// Короткое числовое поле в строке формы — рядом со стрелками или
    /// единицей: секунды, гигабайты.
    func numberFieldWidth() -> some View {
        frame(width: 80)
    }
}
