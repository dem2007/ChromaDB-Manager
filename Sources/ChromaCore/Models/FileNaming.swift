import Foundation

/// Имя файла, предлагаемое в диалоге сохранения.
///
/// **Почему не `CollectionNaming.sanitize`.** Тот санитайзер — про правила
/// ChromaDB: только ASCII, минимальная длина, не похоже на IP-адрес. Для файла
/// это чужие правила, и они дорого стоят: «Прогон 4 Aug 2026 at 20:25»
/// превращался в «4_Aug_2026_at_20_25» — слово, которым человек назвал прогон,
/// из имени пропадало. Найдено на живом экспорте отчёта.
///
/// Файловой системе macOS мешают ровно два знака — `/` и `:`, — и они здесь
/// заменяются. Кириллица остаётся: имя файла человек читает, а не разбирает
/// программой.
public enum FileNaming {
    /// Максимум байт в имени файла на APFS/HFS+ — 255. Кириллица в UTF-8 занимает
    /// два байта на букву, поэтому режем по байтам, а не по символам.
    public static let maximumBytes = 200

    public static func suggested(_ raw: String, suffix: String = "", extension ext: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Ведущая точка прячет файл в Finder — это не то, чего просили.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = String(localized: "без названия") }

        name = truncated(name + suffix)
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// Обрезает по границе символа, чтобы не оставить половину буквы.
    static func truncated(_ name: String) -> String {
        guard name.utf8.count > maximumBytes else { return name }
        var result = ""
        for character in name {
            if (result + String(character)).utf8.count > maximumBytes { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
