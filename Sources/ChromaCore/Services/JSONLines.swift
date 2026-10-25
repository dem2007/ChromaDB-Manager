import Foundation

/// Построчные файлы JSONL, которые приложение дописывает по одной строке:
/// журнал синхронизации, корзина, журнал действий.
///
/// Такой файл всегда может оборваться на полуслове — дозапись прерывается
/// выключением питания или падением, и последняя строка остаётся неполной.
/// Если она обрывается **внутри** многобайтового знака, файл перестаёт быть
/// годным UTF-8 целиком, и `String(contentsOf:encoding:.utf8)` возвращает
/// `nil`. Прежде это стоило **всего файла**: разбор возвращал пустой список,
/// и приложение вело себя так, будто записей нет вовсе.
///
/// Для журнала синхронизации это означало мёртвое восстановление после сбоя:
/// `recover()` не видел ничего незавершённого, старый хвост не удалялся
/// никогда, а `advance()` не находил своей записи и молча ничего не делал.
/// Для корзины — хуже: следующая перезапись файла затирала записи, которых
/// разбор не прочитал.
///
/// Поэтому файл читается **байтами** и режется по переводу строки, а
/// раскодируется каждая строка по отдельности. Обрыв стоит ровно одной
/// строки — той, что и не дописалась.
enum JSONLines {
    /// Строки файла, каждая — отдельно раскодированная.
    ///
    /// Строки, которые не разбираются как UTF-8, пропускаются: это и есть
    /// оборванный хвост. Пустые пропускаются тоже.
    static func read(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return lines(in: data)
    }

    /// То же над готовыми байтами — отдельно, чтобы это можно было проверить
    /// без файла на диске.
    static func lines(in data: Data) -> [String] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
    }

    /// Строки по одной, без копии файла в памяти.
    ///
    /// `read` держит сразу и весь файл, и все его строки: на корзине
    /// в полтора гигабайта это три гигабайта на время запуска. Здесь файл
    /// отображается в память, и строка живёт, пока её разбирают.
    static func forEachLine(at url: URL, _ body: (Data) throws -> Void) rethrows {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return }
        // По сырому буферу и `memchr`: побайтный обход `Data` как коллекции
        // на полутора гигабайтах занимал больше пятнадцати секунд.
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                let found = memchr(base + start, 0x0A, raw.count - start)
                let end = found.map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                if end > start {
                    try autoreleasepool { try body(Data(bytes: base + start, count: end - start)) }
                }
                start = end + 1
            }
        }
    }
}
