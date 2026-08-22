import Foundation

/// Имя файла, привезённое из архива в чужой кодировке.
///
/// **Что случается.** Zip без флага UTF-8 хранит имена байтами кодовой
/// страницы — у русских архивов это CP866. Распаковщик, прочитавший те же
/// байты как MacCyrillic, кладёт на диск файл с именем вроде
/// `20250820_12512_КП_С®бв•ђ≠л© бЃдв.pdf`, и дальше это имя честное: так файл
/// и называется. Приложение его не портило — оно получило испорченное.
///
/// **Почему чиним всё-таки мы.** Имя документа человек читает в выдаче, ищет
/// по нему через MCP и узнаёт по нему свой файл. «`С®бв•ђ≠л© бЃдв`» не
/// опознаётся никак. Перекодировать обратно можно точно: преобразование
/// обратимо, и обратный ход даёт настоящее имя.
///
/// **Путь при этом остаётся диском.** Чинится только `file_name` —
/// человеческое имя; `source_file` и `relative_path` хранят то, как файл
/// называется на самом деле, иначе просмотрщик перестанет его открывать.
/// Расхождение намеренное: одно поле отвечает на «что это за документ»,
/// другое — на «где он лежит».
public enum FileNameEncoding {

    /// Имя, каким его задумывали, — или то же самое, если чинить нечего.
    ///
    /// Условий два, и второе появилось не сразу. Первое: **кириллицы должно
    /// стать строго больше** — здоровое русское имя тоже перекодируется без
    /// ошибки («Приложение.docx» → «ПЁшыюцхэшх.docx»), но прибавки не даёт.
    /// Одного этого условия мало: «Договор ® 2026.pdf» превращается в
    /// «ДюуютюЁ и 2026.pdf», где кириллицы на одну **больше** — знак «®»
    /// перешёл в букву «и», а прочие буквы просто поменялись на другие. Так
    /// правило испортило бы целое имя из-за одного значка.
    ///
    /// Поэтому второе: в имени должно стоять **не меньше двух** знаков из
    /// приметы порчи (`mojibakeMarkers`). У живых испорченных имён их по
    /// шесть, у здорового имени со значком — один.
    public static func repaired(_ name: String) -> String {
        // Имена с диска приходят разложенными (NFD): «й» — это «и» и знак
        // сверху двумя скалярами. Побайтовая перекодировка на таком имени
        // просто откажет, поэтому сперва собранный вид.
        let precomposed = name.precomposedStringWithCanonicalMapping
        guard precomposed.filter(mojibakeMarkers.contains).count >= 2,
              let bytes = precomposed.data(using: macCyrillic),
              let candidate = String(data: bytes, encoding: dosRussian),
              cyrillicCount(candidate) > cyrillicCount(precomposed),
              !candidate.contains(where: { $0.isNewline || $0 == "/" || $0 == ":" })
        else {
            return name
        }
        return candidate
    }

    /// Знаки, которыми выдаёт себя порча: во что превращается кириллица
    /// CP866, прочитанная как MacCyrillic.
    ///
    /// Список не выписан руками, а посчитан по самим кодировкам: байт, за
    /// которым в CP866 стоит кириллическая буква, а в MacCyrillic — не буква,
    /// и есть примета. Выписанный руками список устарел бы молча, а этот
    /// пересчитывается из тех же таблиц, по которым идёт починка.
    static let mojibakeMarkers: Set<Character> = {
        var markers: Set<Character> = []
        for byte in UInt8(0x80)...UInt8(0xFF) {
            let data = Data([byte])
            guard let mac = String(data: data, encoding: macCyrillic)?.first,
                  let dos = String(data: data, encoding: dosRussian)?.first else { continue }
            if cyrillicCount(String(dos)) == 1, cyrillicCount(String(mac)) == 0 {
                markers.insert(mac)
            }
        }
        return markers
    }()

    /// Сколько в строке кириллических букв.
    static func cyrillicCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            (0x0410...0x044F).contains(scalar.value) || scalar.value == 0x0401 || scalar.value == 0x0451
        }.count
    }

    /// MacCyrillic и CP866 — числами через CoreFoundation: `String.Encoding`
    /// их не называет, а `CFStringEncodings` называет.
    static let macCyrillic = encoding(.macCyrillic)
    static let dosRussian = encoding(.dosRussian)

    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }
}
