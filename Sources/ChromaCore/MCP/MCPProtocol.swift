import Foundation

/// Константы протокола MCP, сверенные с актуальной спецификацией 7 августа
/// 2026 года. Не по памяти: ревизия `2026-07-28` объявила протокол
/// stateless и удалила рукопожатие `initialize` целиком.
public enum MCPProtocol {
    /// Основная ревизия — та, ради которой протокол и переписывали: stateless,
    /// без рукопожатия, версия едет в `_meta` каждого запроса.
    public static let version = "2026-07-28"

    /// Ревизии с классическим рукопожатием `initialize`.
    ///
    /// отказался их обслуживать словами «удвоение поверхности протокола
    /// ради никого». Это оказалось неверно: первый же агент, которого стали
    /// подключать, говорит на старой ревизии, и отказ выглядел для человека
    /// как поломка приложения. Решение отменено пользователем.
    ///
    /// Новее — раньше: при согласовании отвечаем самой новой из тех, что
    /// клиент готов принять.
    ///
    /// `2025-11-25` — последняя из них, и спецификация называет именно её
    /// границей старой эпохи. Без неё клиент этой ревизии получал в ответ на
    /// рукопожатие `2025-06-18`, а по HTTP — отказ 400 на свой же заголовок.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Всё, что приложение готово обслуживать, — от новой ревизии к старым.
    public static let supportedVersions = [version] + legacyVersions

    /// Что ответить на `initialize` с такой просьбой.
    ///
    /// Спецификация старой эпохи говорит: сервер отвечает той версией, которую
    /// поддерживает сам, а клиент решает, годится ли она. Просьбу узнаём —
    /// отвечаем ею же; не узнаём — называем свою самую новую старую, и пусть
    /// клиент решает.
    public static func negotiatedLegacyVersion(requested: String?) -> String {
        guard let requested, legacyVersions.contains(requested) else {
            return legacyVersions[0]
        }
        return requested
    }

    /// Версия, которую сервер предполагает, когда клиент её не назвал:
    /// ни в `_meta`, ни заголовком, ни рукопожатием на этом соединении.
    /// Так велит транспорт старой эпохи (2025-06-18, «Protocol Version
    /// Header»): без иных примет сервер **SHOULD** считать версию `2025-03-26`.
    public static let assumedLegacyVersion = "2025-03-26"

    /// Как сообщать о неверных аргументах инструмента.
    ///
    /// До `2025-11-25` спецификация относила «invalid arguments» к ошибкам
    /// протокола (`-32602`); с `2025-11-25` ошибки проверки ввода — это
    /// ошибки выполнения: результат с `isError: true`, по которому модель
    /// исправит вызов сама. Каждой эпохе — её поведение.
    public static func reportsArgumentErrorsAsToolResults(_ version: String) -> Bool {
        version == self.version || version == "2025-11-25"
    }

    /// Само поле, в котором едут версия, возможности и личность клиента.
    public static let metaKey = "_meta"
    /// Префикс полей `_meta`, зарезервированный спецификацией.
    public static let metaProtocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    public static let metaClientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    /// Сведения о сервере в `_meta` ответа — сервер **SHOULD** класть их
    /// в каждый результат: он не опирается на прежние запросы, и клиент тоже.
    public static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    /// Подсказки кэша (`CacheableResult`). В новой ревизии обязательны для
    /// `server/discover` и `tools/list`.
    ///
    /// Сведения о сервере одни для всех — `public` и надолго: меняются они
    /// только с новой версией приложения, то есть с новым процессом.
    public static let discoverCacheTTL = 3_600_000
    /// Список инструментов зависит от ключа (права записи и удаления) и от
    /// переключателя «только чтение» — поэтому `private` и минута: дольше
    /// клиент держал бы список, урезанный или расширенный уже снятыми правами.
    public static let toolsListCacheTTL = 60_000

    // Методы, которые обязан или может обслуживать сервер.
    public static let discoverMethod = "server/discover"
    public static let listToolsMethod = "tools/list"
    public static let callToolMethod = "tools/call"
    public static let cancelledNotification = "notifications/cancelled"
    // Методы старой эпохи. Обслуживаются с 9 августа 2026 года.
    public static let initializeMethod = "initialize"
    /// Уведомление клиента о том, что рукопожатие завершено. Ответа не требует
    /// и не допускает.
    public static let initializedNotification = "notifications/initialized"
    /// Проверка живости. Есть в обеих эпохах, отвечается пустым результатом.
    public static let pingMethod = "ping"

    public static let serverName = "chromadb-manager"

    /// Уведомление нашего собственного транспорта: вспомогательный файл
    /// представляется приложению ключом клиента.
    ///
    /// Не часть MCP и намеренно с чужим для него именем: у stdio нет
    /// заголовков, а ключ обязан как-то доехать. Кладём его в **отдельное
    /// уведомление при подключении**, а не в каждое сообщение агента: так
    /// сообщения агента доезжают до приложения байт в байт, и вспомогательный
    /// файл по-прежнему ничего в них не меняет.
    public static let helloNotification = "chromadb-manager/hello"
}


public extension AppPaths {
    /// Сокет, через который вспомогательный исполняемый файл говорит
    /// с приложением.
    ///
    /// Длина пути имеет значение: в `sockaddr_un` под путь отведено 104 байта,
    /// и это проверено на этой системе, а не взято из памяти. Текущий путь
    /// занимает 63 — запас есть, но менять каталог на более длинный нельзя
    /// не подумав.
    static var mcpSocketFile: URL {
        // Переопределение переменной окружения — не «режим отладки», а то,
        // чем сквозной тест поднимает свой сокет, не трогая рабочий.
        if let override = ProcessInfo.processInfo.environment["CHROMADB_MCP_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appendingPathComponent("mcp.sock")
    }
}
