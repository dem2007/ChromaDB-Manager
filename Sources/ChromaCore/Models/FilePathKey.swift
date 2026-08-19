import Foundation

/// Путь файла как ключ поиска в базе.
///
/// **Почему это вообще нужно.** Одно и то же имя файла Unicode позволяет
/// записать по-разному: «й» — это либо одна буква U+0439, либо «и» плюс
/// отдельный знак кратки U+0306. Файловая система macOS отдаёт имена
/// разложенными, и `source_file` уходил в базу в этой форме. ChromaDB
/// сравнивает строки побайтово, а любой, кто перепечатал путь — агент,
/// пересказавший выдачу, человек, набравший фильтр руками, — набирает его
/// слитно. Файл лежит в коллекции, а `get_file` отвечает «нет документов».
///
/// Найдено живьём: в коллекции `base_adaptive` 27 файлов из 42 не находились
/// по собственному пути из выдачи поиска.
///
/// Каноничная форма здесь — слитная (NFC): в ней путь набирают люди, в ней же
/// его отдают модели и веб-клиенты, и только файловая система стоит особняком.
public enum FilePathKey {
    /// Форма, в которой путь пишется в базу и в манифест.
    public static func canonical(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// Один ли это путь — независимо от того, как записан.
    ///
    /// Сам Swift сравнивает строки канонически и ответил бы «да» и без нас,
    /// а вот ChromaDB, JSON и файловая система работают с байтами — поэтому
    /// сравнение названо вслух там, где от него зависит поведение.
    public static func matches(_ one: String, _ other: String) -> Bool {
        canonical(one) == canonical(other)
    }

    /// Формы, в которых этот путь мог попасть в базу раньше.
    ///
    /// Порядок важен: сначала то, что попросили, потом слитная форма, потом
    /// две разложенные. Первый же ответ с документами — верный, и лишних
    /// запросов к базе не будет.
    ///
    /// Повторы отсеиваются по байтам, а не по `Set<String>`: для Swift все
    /// четыре формы — одна строка, и множество схлопнуло бы список в один
    /// элемент, оставив базу с тем же промахом.
    public static func variants(_ path: String) -> [String] {
        var seen: Set<[UInt8]> = []
        return [
            path,
            canonical(path),
            path.decomposedStringWithCanonicalMapping,
            fileSystemDecomposed(path),
        ].filter { seen.insert(Array($0.utf8)).inserted }
    }

    /// Разложение по правилам файловой системы Apple.
    ///
    /// Не то же самое, что `decomposedStringWithCanonicalMapping`: HFS+ и APFS
    /// оставляют нетронутыми несколько диапазонов — среди них U+2000–U+2FFF,
    /// где живут типографские знаки. Поэтому в имени файла «≠» остаётся одним
    /// знаком, а соседняя «й» разложена на две части, и путь не совпадает ни
    /// со слитной формой, ни с обычной разложенной — только с этой.
    ///
    /// Проверено на живой базе: путь, который агент не смог открыть, совпал
    /// именно здесь.
    public static func fileSystemDecomposed(_ path: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if isKeptWhole(scalar) {
                result.append(scalar)
            } else {
                result.append(contentsOf: String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars)
            }
        }
        return String(result)
    }

    /// Диапазоны, которые файловая система не разлагает (Apple TN1150).
    private static func isKeptWhole(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2000...0x2FFF, 0xF900...0xFA6A, 0xFE30...0xFE44, 0xFE49...0xFE52,
             0xFE54...0xFE66, 0xFE68...0xFE6B, 0xFF01...0xFF5E, 0xFFE0...0xFFE6,
             0x2F800...0x2FA1D:
            return true
        default:
            return false
        }
    }
}
