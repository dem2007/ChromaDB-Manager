import Foundation

/// Вводная фраза списка — та, что кончается двоеточием.
///
/// **Задача.** Пункт списка, оторванный от вводной фразы, теряет подлежащее:
/// «● восстановление работоспособности в течение четырёх часов» — чего
/// восстановление, кто обязан, в рамках чего? Всё это стояло строкой выше,
/// в «Исполнитель обязан обеспечить:», и в вектор пункта не попало.
///
/// **Почему только двоеточие, а не «предыдущий блок вообще».** Замер на 150
/// файлах пользователя: 907 чанков adaptive начинаются пунктом и не содержат
/// предшествующего блока — но двоеточием кончается родитель лишь у 124 из них.
/// Остальные 783 — нумерованные пункты постановлений: `2. Оператору…`,
/// `11. Наборы данных…`. Их «родитель» — предыдущий пункт того же перечня,
/// и приписать его значило бы объявить пункт 11 подчинённым пункту 10.
/// Правило «брать предыдущий блок» испортило бы в шесть раз больше чанков,
/// чем починило.
///
/// **Куда попадает найденное.** Туда же, куда строка «Документ → Раздел»
///: в текст **для вектора**, но не в документ. Человек и агент читают
/// чанк как он есть, `content_hash` остаётся хэшем файла, и в базе ничего
/// не дублируется.
public enum ListLeadIns {
    /// Длиннее этого вводная фраза не бывает — то, что длиннее, это уже абзац,
    /// который кончился двоеточием случайно, и в вектор пункта он принесёт
    /// больше своего смысла, чем чужого.
    public static let maximumLength = 200

    /// Короче этого — не фраза, а обрывок вроде «Приложение:».
    static let minimumLength = 12

    /// Найденная вводная фраза и участок текста, к которому она относится.
    public struct LeadIn: Sendable, Hashable {
        public let text: String
        /// Смещения списка в `plainText`: от первого пункта до конца последнего.
        public let range: Range<Int>

        public init(text: String, range: Range<Int>) {
            self.text = text
            self.range = range
        }
    }

    /// Все списки документа с их вводными фразами, в порядке текста.
    ///
    /// Блоки — куски между пустыми строками: ровно то, чем их считает нарезка,
    /// и то, что после сшивки PDF наконец соответствует абзацам.
    public static func leadIns(in text: String) -> [LeadIn] {
        guard !text.isEmpty else { return [] }

        var result: [LeadIn] = []
        var offset = 0
        var pending: (text: String, end: Int)?
        var listStart: Int?
        var listEnd = 0

        func close() {
            if let pending, let start = listStart, listEnd > start {
                result.append(LeadIn(text: pending.text, range: start..<listEnd))
            }
            listStart = nil
        }

        for block in text.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            let blockStart = offset
            offset += block.count + 2

            guard !trimmed.isEmpty else { continue }

            if isListItem(trimmed) {
                // Пункт продолжает список, если вводная фраза уже найдена.
                if pending != nil {
                    if listStart == nil { listStart = blockStart }
                    listEnd = blockStart + block.count
                }
                continue
            }

            // Не пункт — список кончился.
            close()
            pending = isLeadIn(trimmed) ? (trimmed, blockStart + block.count) : nil
        }
        close()
        return result
    }

    /// Вводная фраза для смещения, или `nil`, если это смещение не в списке.
    public static func leadIn(at offset: Int, in leadIns: [LeadIn]) -> String? {
        leadIns.first { $0.range.contains(offset) }?.text
    }

    /// Блок, кончающийся двоеточием и годный в роли вводной фразы.
    static func isLeadIn(_ block: String) -> Bool {
        guard block.hasSuffix(":") else { return false }
        guard block.count >= minimumLength, block.count <= maximumLength else { return false }
        // Сам пункт списка вводной фразой не бывает: иначе перечень, где
        // у каждого пункта есть подпункты, объявил бы вводной фразой каждый
        // свой пункт по очереди.
        return !isListItem(block)
    }

    /// Пункт списка: знак перечисления или номер пункта в начале блока.
    ///
    /// Ровно то же правило, по которому сшивка PDF отделяет пункты в свои
    /// блоки, — общее на двоих, чтобы не разошлось.
    static func isListItem(_ block: String) -> Bool {
        PDFTextReflow.startsWithListMarker(block)
    }
}
