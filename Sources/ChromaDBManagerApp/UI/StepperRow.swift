import SwiftUI

/// Число со стрелками — одной строкой формы: подпись слева, значение и
/// стрелки справа, как в Системных настройках.
///
/// Метка `Stepper` сама по себе становится подписью строки и прижимает
/// значение к ней, а стрелки уезжают к краю; значение отдельно от стрелок
/// держит их вместе.
struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    /// Как показать число словами — «300 знаков», «не отбрасывать».
    var display: ((Int) -> String)?

    init(
        _ title: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int = 1,
        display: ((Int) -> String)? = nil
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.display = display
    }

    var body: some View {
        LabeledContent(title) {
            if let display {
                // Значение словами («300 знаков», «не отбрасывать») в поле не
                // впишешь — текст и стрелки.
                Text(display(value))
                    .monospacedDigit()
            } else {
                // Просто число — полем с рамкой (v4 A5): его можно и ввести,
                // а не только нащёлкать стрелками.
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .numberFieldWidth()
            }
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
        }
    }

    /// Введённое руками — в пределах, как и нащёлканное стрелками.
    private var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

/// То же для дробного числа — секунды, паузы. Полем со стрелками (v6 A2),
/// единица — в подписи («Таймаут, с»).
struct DecimalStepperRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: clamped, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .numberFieldWidth()
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
        }
    }

    /// Введённое руками — в пределах, как и нащёлканное стрелками.
    private var clamped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

/// Слайдер строкой формы: подпись слева, слайдер и значение справа.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        display: @escaping (Double) -> String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.display = display
    }

    var body: some View {
        LabeledContent(title) {
            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
            Text(display(value))
                .monospacedDigit()
        }
    }
}

#Preview {
    Form {
        StepperRow("Записей в выборке" as String, value: .constant(500), in: 50...5000, step: 50)
        StepperRow("Цель" as String, value: .constant(300), in: 50...4000, step: 50) { "\($0) знаков" }
        SliderRow("Перекрытие" as String, value: .constant(15), in: 0...50, step: 5) { "\(Int($0)) %" }
    }
    .formStyle(.grouped)
}
