import XCTest
import SwiftUI
import AppKit
@testable import ChromaDBManagerApp

@MainActor
final class ZZLayoutCheckTests: XCTestCase {
    struct Row: View {
        let custom: Bool
        var body: some View {
            HStack(spacing: 8) {
                if custom {
                    Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.chromaCheckbox)
                } else {
                    Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.checkbox)
                }
                Text("Отчёты/2026/Акт-сдачи-приёмки.docx").font(Theme.Font.body)
                    .lineLimit(1).truncationMode(.middle)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: XKey.self, value: proxy.frame(in: .global).minX)
                    })
                Spacer(minLength: 0)
            }
            .frame(width: 600)
        }
    }

    struct XKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    func testWhereTheTextStarts() {
        for custom in [false, true] {
            var x: CGFloat = -1
            let view = Row(custom: custom).onPreferenceChange(XKey.self) { x = $0 }
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            print("PROBE \(custom ? "свой флажок" : "родной") : текст начинается с x = \(Int(x))")
        }
    }
}
