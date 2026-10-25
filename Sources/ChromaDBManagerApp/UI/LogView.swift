import SwiftUI

/// Журнал строк моноширинным шрифтом — вывод сервера, события, вывод команд.
///
/// Ленивый: журнал на тысячи строк не строит тысячи видов разом. Внутреннего
/// заголовка нет — место журнала называет вкладка или секция вокруг.
/// «Следить за концом» — переключатель у того, кто журнал показывает (в
/// тулбаре экрана); здесь только поведение: пока он включён, новая строка
/// прокручивает журнал вниз.
struct LogView: View {
    let lines: [String]
    var followsEnd: Bool = true
    /// Журнал внутри формы: строка формы сама высоты не даёт, поэтому
    /// у компактного журнала она своя — и числом, а числа живут только в `UI/`.
    var compact: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        line(lines[index])
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .copyable(lines.joined(separator: "\n"))
                .padding()
            }
            .frame(minHeight: compact ? 160 : nil, idealHeight: compact ? 220 : nil, maxHeight: compact ? 320 : nil)
            // От верха (v4): с `.bottom` короткий журнал прижимался к низу
            // с пустотой сверху. К последней строке — прокруткой, и только
            // когда журнал длиннее окна: иначе прокручивать некуда.
            .defaultScrollAnchor(.top)
            .onAppear {
                guard followsEnd, !lines.isEmpty else { return }
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
            // По числу строк и последней строке разом: буфер с пределом
            // (вывод сервера держит 1000 строк) перестаёт расти, и одно число
            // строк слежение бы остановило; два отдельных наблюдения крутили
            // бы к концу дважды на каждую строку.
            .onChange(of: Tail(count: lines.count, last: lines.last)) { _, tail in
                guard followsEnd, tail.count > 0 else { return }
                proxy.scrollTo(tail.count - 1, anchor: .bottom)
            }
            .onChange(of: followsEnd) { _, follows in
                guard follows, !lines.isEmpty else { return }
                proxy.scrollTo(lines.count - 1, anchor: .bottom)
            }
        }
    }
}

/// Конец журнала — по нему видно, что пришла новая строка.
private struct Tail: Equatable {
    let count: Int
    let last: String?
}

/// «[22:31:07] ● » — метка времени и значок строки журнала событий.
private let stampPrefix = try! Regex(#"^\[\d{2}:\d{2}:\d{2}\] \S "#)

extension LogView {
    /// Строка журнала: перенос продолжается под текстом, а не от левого
    /// края (v4) — метка времени отдельно, сообщение рядом.
    @ViewBuilder
    fileprivate func line(_ text: String) -> some View {
        if let match = text.prefixMatch(of: stampPrefix) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: String(text[match.range]))
                Text(verbatim: String(text[match.range.upperBound...]))
            }
        } else {
            Text(verbatim: text)
        }
    }
}

#Preview {
    LogView(lines: (1...200).map { "22:31:\(String(format: "%02d", $0 % 60)) [ChromaDB] Строка журнала номер \($0)" })
        .frame(width: 600, height: 300)
}
