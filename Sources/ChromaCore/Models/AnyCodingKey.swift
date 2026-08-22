import Foundation

/// Ключ, принимающий любое имя, — чтобы спросить у разбираемого файла, **что
/// в нём вообще есть**.
///
/// Типизированный контейнер отвечает только про перечисленные ключи, поэтому
/// незнакомую настройку через него не увидеть: она не «пришла с ошибкой», её
/// просто нет ни в одном ответе. Свободный ключ и нужен затем, чтобы
/// сопоставить содержимое файла со списком известного.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
