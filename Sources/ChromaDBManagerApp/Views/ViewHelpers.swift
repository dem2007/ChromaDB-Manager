import SwiftUI
import AppKit
import ChromaCore

// Помощники экранов, пережившие переход на системные компоненты: чисел и
// своего оформления в них нет, поэтому они не в `UI/`.

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

extension View {
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
                    .font(.caption)
            }
            if let footnote { footnote() }
        }
    }
}

extension BinaryFloatingPoint {
    /// Дробное число в локали интерфейса (v4 A3): «66,4», «5 282,5», а не
    /// «66.4» из `String(format:)` рядом с «379 473» из `formatted()`.
    func decimal(_ digits: Int) -> String {
        Double(self).formatted(.number.precision(.fractionLength(digits)))
    }
}

extension ChunkingConfiguration {
    /// Параметры нарезки подписанными строками, своими для каждой стратегии
    /// (v5): «База — ≈ 512 токенов». Стратегия сюда не входит — её подпись
    /// своя у каждого места. Для экранов; `summaryText` ядра — для журнала.
    var parameterRows: [(String, String)] {
        // «≈ 512 токенов», «2 048 символов»: знак приблизительности — перед
        // числом, а не приклеенным к слову.
        let measure: (String) -> String = { amount in
            sizeUnit == .tokens
                ? String(localized: "≈ \(amount) токенов")
                : String(localized: "\(amount) символов")
        }
        var rows: [(String, String)] = []
        switch strategy {
        case .fixed, .recursive:
            rows.append((String(localized: "Размер"), measure(chunkSize.formatted())))
            rows.append((String(localized: "Перекрытие"), (overlapPercent / 100).formatted(.percent.precision(.fractionLength(0)))))
        case .documentBased:
            rows.append((String(localized: "Формат"), sourceFormat.title))
            rows.append((String(localized: "Секции до"), measure(maxSectionSize.formatted())))
            rows.append((String(localized: "Крупные секции"), oversizedFallback.title))
        case .hierarchical:
            rows.append((String(localized: "Родитель"), measure(parentChunkSize.formatted())))
            rows.append((String(localized: "Ребёнок"), measure(childChunkSize.formatted())))
        case .semantic:
            rows.append((String(localized: "Порог"), "\(thresholdMode.title) \(Int(thresholdValue.rounded()))"))
            rows.append((String(localized: "Диапазон"), measure("\(minChunkSize.formatted())–\(maxChunkSize.formatted())")))
        case .adaptive:
            rows.append((String(localized: "База"), measure(baseChunkSize.formatted())))
            rows.append((String(localized: "Диапазон"), measure("\(minChunkSize.formatted())–\(maxChunkSize.formatted())")))
            rows.append((String(localized: "Чувствительность"), sensitivity.decimal(1)))
        case .llmBased:
            rows.append((String(localized: "Модель"), chatModel ?? String(localized: "не выбрана")))
            rows.append((String(localized: "Дробность"), granularity.title))
        }
        return rows
    }

    /// Одной строкой — где на параметр не хватает отдельной строки формы.
    var parameterLine: String {
        parameterRows.map { "\($0.0.lowercased()) \($0.1)" }.joined(separator: " · ")
    }
}
